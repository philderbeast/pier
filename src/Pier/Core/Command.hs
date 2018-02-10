-- | A generic approach to building and caching outputs hermetically.
--
-- Output format: _pier/artifact/HASH/path/to/files
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE TypeOperators #-}
module Pier.Core.Command
    ( artifactRules
    , Output
    , output
    , prog
    , progA
    , progTemp
    , input
    , inputs
    , inputList
    , message
    , withCwd
    , runCommand
    , runCommandStdout
    , runCommand_
    , Command
    , Artifact
    , externalFile
    , (/>)
    , pathIn
    , pathOut
    , replaceArtifactExtension
    , readArtifact
    , readArtifactB
    , doesArtifactExist
    , writeArtifact
    , matchArtifactGlob
    , unfreezeArtifacts
    , shadow
    , callArtifact
    , createDirectoryA
    ) where

import Control.Monad (forM_, when, unless)
import Control.Monad.IO.Class
import Crypto.Hash.SHA256
import Data.ByteString.Base64
import Data.Semigroup
import Data.Set (Set)
import Development.Shake
import Development.Shake.Classes hiding (hash)
import Development.Shake.FilePath
import Distribution.Simple.Utils (matchDirFileGlob)
import GHC.Generics
import System.Directory as Directory
import System.Exit (ExitCode(..))
import System.Posix.Files (createSymbolicLink)
import System.Process.Internals (translate)

import qualified Data.Binary as Binary
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

import Pier.Core.Directory
import Pier.Core.Persistent
import Pier.Core.Run
import Pier.Orphans ()

-- TODO: reconsider names in this module

data Command = Command
    { _commandProgs :: [Prog]
    , commandInputs :: Set Artifact
    }
    deriving (Typeable, Eq, Generic, Hashable, Binary, NFData)

data Call
    = CallEnv String -- picked up from $PATH
    | CallArtifact Artifact
    | CallTemp FilePath -- Local file to this Command
                        -- (e.g. generated by an earlier call)
                        -- (This is a hack around shake which tries to resolve
                        -- local files in the env.)
    deriving (Typeable, Eq, Generic, Hashable, Binary, NFData)

data Prog
    = ProgCall { _progCall :: Call
           , _progArgs :: [String]
           , progCwd :: FilePath  -- relative to the root of the sandbox
           }
    | Message String
    | Shadow Artifact FilePath
    deriving (Typeable, Eq, Generic, Hashable, Binary, NFData)

instance Monoid Command where
    Command ps is `mappend` Command ps' is' = Command (ps ++ ps') (is <> is')
    mempty = Command [] Set.empty

instance Semigroup Command

-- TODO: allow prog taking Artifact and using it as input

prog :: String -> [String] -> Command
prog p as = Command [ProgCall (CallEnv p) as "."] Set.empty

progA :: Artifact -> [String] -> Command
progA p as = Command [ProgCall (CallArtifact p) as "."] (Set.singleton p)

progTemp :: FilePath -> [String] -> Command
progTemp p as = Command [ProgCall (CallTemp p) as "."] Set.empty

message :: String -> Command
message s = Command [Message s] Set.empty

withCwd :: FilePath -> Command -> Command
withCwd path (Command ps as)
    | isAbsolute path = error $ "withCwd: expected relative path, got " ++ show path
    | otherwise = Command (map setPath ps) as
  where
    setPath m@Message{} = m
    setPath p = p { progCwd = path }

input :: Artifact -> Command
input = inputs . Set.singleton

inputList :: [Artifact] -> Command
inputList = inputs . Set.fromList

inputs :: Set Artifact -> Command
inputs = Command []

-- | Make a "shadow" copy of the given input artifact's by create a symlink of
-- this artifact (if it is a file) or of each sub-file (transitively, if it is
-- a directory).
--
-- The result may be captured as output, for example when grouping multiple outputs
-- of separate commands into a common directory structure.
shadow :: Artifact -> FilePath -> Command
shadow a f
    | isAbsolute f = error $ "shadowArtifact: need relative destination, found "
                            ++ show f
    | otherwise = Command [Shadow a f] Set.empty

data Output a = Output [FilePath] (Hash -> a)

instance Functor Output where
    fmap f (Output g h) = Output g (f . h)

instance Applicative Output where
    pure = Output [] . const
    Output f g <*> Output f' g' = Output (f ++ f') (g <*> g')

output :: FilePath -> Output Artifact
output f
    | normalise f == "." = error $ "Can't output empty path " ++ show f
    | isAbsolute f = error $ "Can't output absolute path " ++ show f
    | otherwise = Output [f] $ flip Artifact (normalise f) . Built

-- | Unique identifier of a command
newtype Hash = Hash B.ByteString
    deriving (Show, Eq, Ord, Binary, NFData, Hashable, Generic)

makeHash :: Binary a => a -> Hash
makeHash = Hash . fixChars . dropPadding . encode . hashlazy . Binary.encode
  where
    -- Remove slashes, since the strings will appear in filepaths.
    -- Also remove `+` to reduce shell errors.
    fixChars = BC.map $ \case
                                '/' -> '-'
                                '+' -> '.'
                                c -> c
    -- Padding just adds noise, since we don't have length requirements (and indeed
    -- every sha256 hash is 32 bytes)
    dropPadding c
        | BC.last c == '=' = BC.init c
        -- Shouldn't happen since each hash is the same length:
        | otherwise = c

hashDir :: Hash -> FilePath
hashDir h = artifactDir </> hashString h

artifactDir :: FilePath
artifactDir = pierFile "artifact"

hashString :: Hash -> String
hashString (Hash h) = BC.unpack h

data Artifact = Artifact Source FilePath
    deriving (Eq, Ord, Generic)

instance Show Artifact where
    show (Artifact External f) = "external:" ++ show f
    show (Artifact (Built h) f) = hashString h ++ ":" ++ show f

instance Hashable Artifact
instance Binary Artifact
instance NFData Artifact

data Source = Built Hash | External
    deriving (Show, Eq, Ord, Generic)

instance Hashable Source
instance Binary Source
instance NFData Source

externalFile :: FilePath -> Artifact
externalFile = Artifact External . normalise

(/>) :: Artifact -> FilePath -> Artifact
Artifact source f /> g = Artifact source $ normalise $ f </> g

infixr 5 />  -- Same as </>

-- TODO: go back to </> for artifacts (or some one-sided operator),
-- and add a check that no two inputs for the same Command are
-- subdirs of each other

artifactRules :: Rules ()
artifactRules = commandRules >> writeArtifactRules

data CommandQ = CommandQ
    { commandQCmd :: Command
    , _commandQOutputs :: [FilePath]
    }
    deriving (Eq, Generic)

instance Show CommandQ where
    show CommandQ { commandQCmd = Command progs _ }
        = let msgs = List.intercalate "; " [m | Message m <- progs]
          in "Command" ++
                if null msgs
                    then ""
                    else ": " ++ msgs

instance Hashable CommandQ
instance Binary CommandQ
instance NFData CommandQ

type instance RuleResult CommandQ = Hash

-- TODO: sanity-check filepaths; for example, normalize, should be relative, no
-- "..", etc.
commandHash :: CommandQ -> Action Hash
commandHash cmdQ = do
    let externalFiles = [f | Artifact External f <- Set.toList $ commandInputs
                                                        $ commandQCmd cmdQ
                           , isRelative f
                        ]
    need externalFiles
    -- TODO: streaming hash
    userFileHashes <- liftIO $ map hash <$> mapM B.readFile externalFiles
    return $ makeHash ("commandHash", cmdQ, userFileHashes)

runCommand :: Output t -> Command -> Action t
runCommand (Output outs mk) c
    = mk <$> askPersistent (CommandQ c outs)

runCommandStdout :: Command -> Action String
runCommandStdout c = do
    out <- runCommand (output stdoutOutput) c
    liftIO $ readFile $ pathIn out

runCommand_ :: Command -> Action ()
runCommand_ = runCommand (pure ())

commandRules :: Rules ()
commandRules = addPersistent $ \cmdQ@(CommandQ (Command progs inps) outs) -> do
    putChatty $ showCommand cmdQ
    h <- commandHash cmdQ
    createArtifacts h $ \resultDir -> do
        -- Run the command within a separate temporary directory.
        -- When it's done, we'll move the explicit set of outputs into
        -- the result location.
        tmpDir <- createSystemTempDirectory (hashString h)
        let tmpPathOut = (tmpDir </>) . pathOut

        liftIO $ collectInputs inps tmpDir
        mapM_ (createParentIfMissing . tmpPathOut) outs

        -- Run the command, and write its stdout to a special file.
        stdoutStr <- B.concat <$> mapM (readProg tmpDir) progs

        let stdoutPath = tmpPathOut stdoutOutput
        createParentIfMissing stdoutPath
        liftIO $ B.writeFile stdoutPath stdoutStr

        -- Check that all the output files exist, and move them
        -- into the output directory.
        liftIO $ forM_ outs $ \f -> do
            let src = tmpPathOut f
            let dest = resultDir </> f
            exist <- Directory.doesPathExist src
            unless exist $
                error $ "runCommand: missing output "
                        ++ show f
                        ++ " in temporary directory "
                        ++ show tmpDir
            createParentIfMissing dest
            renamePath src dest

        -- Clean up the temp directory, but only if the above commands succeeded.
        liftIO $ removeDirectoryRecursive tmpDir
    return h

putChatty :: String -> Action ()
putChatty s = do
    v <- shakeVerbosity <$> getShakeOptions
    when (v >= Chatty) $ putNormal s

pathOut :: FilePath -> FilePath
pathOut f = artifactDir </> "out" </> f

-- TODO: more hermetic?
collectInputs :: Set Artifact -> FilePath -> IO ()
collectInputs inps tmp = do
    let inps' = dedupArtifacts inps
    checkAllDistinctPaths inps'
    liftIO $ mapM_ (linkArtifact tmp) inps'

-- | Create a directory containing Artifacts.
--
-- If the output directory already exists, don't do anything.  Otherwise, run
-- the given function with a temporary directory, and then move that directory
-- atomically to the final output directory for those Artifacts.
-- Files and (sub)directories, as well as the directory itself, will
-- be made read-only.
createArtifacts :: Hash -> (FilePath -> Action ()) -> Action ()
createArtifacts h act = do
    let destDir = hashDir h
    -- Skip if the output directory already exists; we'll produce it atomically
    -- below.  This could happen if Shake's database was cleaned, or if the
    -- action stops before Shake registers it as complete, due to either a
    -- synchronous or asynchronous exception.
    exists <- liftIO $ Directory.doesDirectoryExist destDir
    unless exists $ do
        tempDir <- createSystemTempDirectory $ hashString h ++ "-result"
        -- Run the given action.
        act tempDir
        liftIO $ do
            -- Move the created directory to its final location,
            -- with all the files and directories inside set to
            -- read-only.
            getRegularContents tempDir
                >>= mapM_ (forFileRecursive_ freezePath . (tempDir </>))
            createParentIfMissing destDir
            Directory.renameDirectory tempDir destDir
            -- Also set the directory itself to read-only, but wait
            -- until the last step since read-only files can't be moved.
            freezePath destDir

-- Call a process inside the given directory and capture its stdout.
-- TODO: more flexibility around the env vars
-- Also: limit valid parameters for the *prog* binary (rather than taking it
-- from the PATH that the `pier` executable sees).
readProg :: FilePath -> Prog -> Action B.ByteString
readProg _ (Message s) = do
    putNormal s
    return B.empty
readProg dir (ProgCall p as cwd) = readProgCall dir p as cwd
readProg dir (Shadow a0 f0) = do
    liftIO $ linkShadow dir a0 f0
    return B.empty

readProgCall :: FilePath -> Call -> [String] -> FilePath -> Action BC.ByteString
readProgCall dir p as cwd = do
    -- hack around shake weirdness w.r.t. relative binary paths
    let p' = case p of
                CallEnv s -> s
                CallArtifact f -> dir </> pathIn f
                CallTemp f -> dir </> pathOut f
    (ret, Stdout out, Stderr err)
        <- quietly $ command
                    [ Cwd $ dir </> cwd
                    , Env defaultEnv
                    -- stderr will get printed if there's an error.
                    , EchoStderr False
                    ]
                    p' (map (spliceTempDir dir) as)
    case ret of
        ExitSuccess -> return out
        ExitFailure ec -> do
            v <- shakeVerbosity <$> getShakeOptions
            fail $ if v < Loud
                -- TODO: remove trailing newline
                then err
                else unlines
                        [ showProg (ProgCall p as cwd)
                        , "Working dir: " ++ translate (dir </> cwd)
                        , "Exit code: " ++ show ec
                        , "Stderr:"
                        , err
                        ]

linkShadow :: FilePath -> Artifact -> FilePath -> IO ()
linkShadow dir a0 f0 = do
    let out = dir </> pathOut f0
    createParentIfMissing out
    rootDir <- Directory.getCurrentDirectory
    deepLink (rootDir </> pathIn a0) out
  where
    deepLink a f = do
        isDir <- Directory.doesDirectoryExist a
        if isDir
            then do
                    Directory.createDirectoryIfMissing False f
                    cs <- getRegularContents a
                    mapM_ (\c -> deepLink (a </> c) (f </> c)) cs
            else createSymbolicLink a f

showProg :: Prog -> String
showProg (Shadow a f) = unwords ["Shadow:", pathIn a, "=>", pathOut f]
showProg (Message m) = "Message: " ++ show m
showProg (ProgCall call args cwd) =
    wrapCwd
        . List.intercalate " \\\n    "
        $ showCall call : args
  where
    wrapCwd s = case cwd of
                    "." -> s
                    _ -> "(cd " ++ translate cwd ++ " &&\n " ++ s ++ ")"

    showCall (CallArtifact a) = pathIn a
    showCall (CallEnv f) = f
    showCall (CallTemp f) = pathOut f

showCommand :: CommandQ -> String
showCommand (CommandQ (Command progs inps) outputs) = unlines $
    map showOutput outputs
    ++ map showInput (Set.toList inps)
    ++ map showProg progs
  where
    showInput i = "Input: " ++ pathIn i
    showOutput a = "Output: " ++ pathOut a

stdoutOutput :: FilePath
stdoutOutput = "_stdout"

defaultEnv :: [(String, String)]
defaultEnv = [("PATH", "/usr/bin:/bin")]

spliceTempDir :: FilePath -> String -> String
spliceTempDir tmp = T.unpack . T.replace (T.pack "${TMPDIR}") (T.pack tmp) . T.pack

checkAllDistinctPaths :: Monad m => [Artifact] -> m ()
checkAllDistinctPaths as =
    case Map.keys . Map.filter (> 1) . Map.fromListWith (+)
            . map (\a -> (pathIn a, 1 :: Integer)) $ as of
        [] -> return ()
        -- TODO: nicer error, telling where they came from:
        fs -> error $ "Artifacts generated from more than one command: " ++ show fs

-- Remove duplicate artifacts that are both outputs of the same command, and where
-- one is a subdirectory of the other (for example, constructed via `/>`).
dedupArtifacts :: Set Artifact -> [Artifact]
dedupArtifacts = loop . Set.toAscList
  where
    -- Loop over artifacts built from the same command.
    -- toAscList plus lexicographic sorting means that
    -- subdirectories with the same hash will appear consecutively after directories
    -- that contain them.
    loop (a@(Artifact (Built h) f) : Artifact (Built h') f' : fs)
        | h == h', (f <//> "*") ?== f' = loop (a:fs)
    loop (f:fs) = f : loop fs
    loop [] = []

freezePath :: FilePath -> IO ()
freezePath f = getPermissions f >>= setPermissions f . setOwnerWritable False

-- | Make all artifacts user-writable, so they can be deleted by `clean-all`.
unfreezeArtifacts :: IO ()
unfreezeArtifacts = do
    exists <- Directory.doesDirectoryExist artifactDir
    when exists $ forFileRecursive_ unfreeze artifactDir
  where
    unfreeze f = do
        sym <- pathIsSymbolicLink f
        unless sym $ getPermissions f >>= setPermissions f . setOwnerWritable True

-- TODO: don't loop on symlinks, and be more efficient?
forFileRecursive_ :: (FilePath -> IO ()) -> FilePath -> IO ()
forFileRecursive_ act f = do
    isDir <- Directory.doesDirectoryExist f
    if not isDir
        then act f
        else do
            getRegularContents f >>= mapM_ (forFileRecursive_ act . (f </>))
            act f

getRegularContents :: FilePath -> IO [FilePath]
getRegularContents f =
    filter (not . specialFile) <$> Directory.getDirectoryContents f
  where
    specialFile "." = True
    specialFile ".." = True
    specialFile _ = False

-- Symlink the artifact into the given destination directory.
linkArtifact :: FilePath -> Artifact -> IO ()
linkArtifact _ (Artifact External f)
    | isAbsolute f = return ()
linkArtifact dir a = do
    curDir <- getCurrentDirectory
    let realPath = curDir </> pathIn a
    let localPath = dir </> pathIn a
    checkExists realPath
    createParentIfMissing localPath
    createSymbolicLink realPath localPath
  where
    -- Sanity check
    checkExists f = do
        isFile <- Directory.doesFileExist f
        isDir <- Directory.doesDirectoryExist f
        when (not isFile && not isDir)
            $ error $ "linkArtifact: source does not exist: " ++ show f
                        ++ " for artifact " ++ show a


pathIn :: Artifact -> FilePath
pathIn (Artifact External f) = f
pathIn (Artifact (Built h) f) = hashDir h </> f

replaceArtifactExtension :: Artifact -> String -> Artifact
replaceArtifactExtension (Artifact s f) ext
    = Artifact s $ replaceExtension f ext

readArtifact :: Artifact -> Action String
readArtifact (Artifact External f) = readFile' f -- includes need
readArtifact f = liftIO $ readFile $ pathIn f

readArtifactB :: Artifact -> Action B.ByteString
readArtifactB (Artifact External f) = need [f] >> liftIO (B.readFile f)
readArtifactB f = liftIO $ B.readFile $ pathIn f

data WriteArtifactQ = WriteArtifactQ
    { writePath :: FilePath
    , writeContents :: String
    }
    deriving (Eq, Typeable, Generic, Hashable, Binary, NFData)

instance Show WriteArtifactQ where
    show w = "Write " ++ writePath w

type instance RuleResult WriteArtifactQ = Artifact

writeArtifact :: FilePath -> String -> Action Artifact
writeArtifact path contents = askPersistent $ WriteArtifactQ path contents

writeArtifactRules :: Rules ()
writeArtifactRules = addPersistent
        $ \WriteArtifactQ {writePath = path, writeContents = contents} -> do
    let h = makeHash . T.encodeUtf8 . T.pack
                $ "writeArtifact: " ++ contents
    createArtifacts h $ \tmpDir -> do
        let out = tmpDir </> path
        createParentIfMissing out
        liftIO $ writeFile out contents
    return $ Artifact (Built h) $ normalise path

doesArtifactExist :: Artifact -> Action Bool
doesArtifactExist (Artifact External f) = Development.Shake.doesFileExist f
doesArtifactExist f = liftIO $ Directory.doesFileExist (pathIn f)

-- Note: this throws an exception if there's no match.
matchArtifactGlob :: Artifact -> FilePath -> Action [FilePath]
-- TODO: match the behavior of Cabal
matchArtifactGlob (Artifact External f) g
    = getDirectoryFiles f [g]
matchArtifactGlob a g
    = liftIO $ matchDirFileGlob (pathIn a) g

-- TODO: merge more with above code?  How hermetic should it be?
callArtifact :: Set Artifact -> Artifact -> [String] -> IO ()
callArtifact inps bin args = do
    tmp <- liftIO $ createSystemTempDirectory "exec"
    -- TODO: preserve if it fails?  Make that a parameter?
    collectInputs (Set.insert bin inps) tmp
    cmd_ [Cwd tmp]
        (tmp </> pathIn bin) args
    -- Clean up the temp directory, but only if the above commands succeeded.
    liftIO $ removeDirectoryRecursive tmp

createDirectoryA :: FilePath -> Command
createDirectoryA f = prog "mkdir" ["-p", pathOut f]

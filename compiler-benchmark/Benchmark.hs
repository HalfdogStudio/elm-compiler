module Main where

import Control.Monad (unless, forM_, void, when)
import Data.Attoparsec.Text (parseOnly, maybeResult)
import Data.IntMap ()
import qualified Data.Text.IO as Text
import Data.Text as Text (Text, pack)
import Data.Foldable (find)
import GHC.RTS.TimeAllocProfile (timeAllocProfile, profileHotCostCentres) 
import GHC.RTS.TimeAllocProfile.Types (CostCentre, TimeAllocProfile, costCentreNodes, profileCostCentreTree, costCentreName)
import System.Directory (doesDirectoryExist, copyFile, setCurrentDirectory, getCurrentDirectory, createDirectoryIfMissing, getDirectoryContents, removeDirectoryRecursive)
import System.Exit (ExitCode(ExitSuccess))
import System.FilePath ((</>))
import System.Process (rawSystem)

data Repo = Repo 
    { projectName :: String
    , path :: FilePath
    , branch :: String
    }

-- Version of the Elm compiler that is being used.
data Version
    = Gold
    | Test
    deriving Show

golden :: [Repo]
golden = 
    [ Repo 
        { projectName = "elm-make"
        , path = "https://github.com/elm-lang/elm-make.git"
        , branch = "master"
        }
    , Repo
        { projectName = "elm-package"
        , path = "https://github.com/elm-lang/elm-package.git"
        , branch = "master"
        }
    , Repo
        { projectName = "elm-compiler"
        , path = "https://github.com/elm-lang/elm-compiler.git"
        , branch = "master"
        }
    ]   

dev :: [Repo]
dev =
    [ Repo
        { projectName = "elm-make"
        , path = ""
        , branch = "master"
        }
    ] 

-- Names of annotated cost centres in elm-compiler and elm-make. Must be kept
-- in sync with the SCC annotations in elm-compiler and elm-make (which must
-- also be kept in sync with each other). Used to extract cost centre data
-- from the results of profiling the compiler execution. 
costCentreNames :: [Text]
costCentreNames = map Text.pack
    [ "parsing"
    ]

main :: IO ()
main = do
    root <- (</> "compiler-benchmark") <$> getCurrentDirectory
    inDirectory root $ do
        -- Elm projects
        createDirectoryIfMissing True "benchmark-projects"
        inDirectory "benchmark-projects" $ do
            todoMvcExists <- doesDirectoryExist "elm-todomvc"
            unless todoMvcExists . void $
                git ["clone", "https://github.com/evancz/elm-todomvc", "elm-todomvc"]
            
        -- Source 
        createDirectoryIfMissing True "benchmark-src"

        -- elm-compiler
        makeSrcRepo "elm-compiler" 
        -- inDirectory "benchmark-src/elm-compiler" $ do
        --     git [ "checkout", "0.17", "--quiet" ]

        -- elm-package
        makeSrcRepo "elm-package" 
        -- inDirectory "benchmark-src/elm-package" $ do
        --     git [ "checkout", "0.17", "--quiet" ]

        -- elm-make
        makeSrcRepo "elm-make" 
        inDirectory "benchmark-src/elm-make" $ do
            -- git [ "checkout", "0.17", "--quiet" ]
            cabal ["sandbox", "init"]
            cabal ["sandbox", "add-source", root </> "benchmark-src" </> "elm-compiler"]
            cabal ["sandbox", "add-source", root </> "benchmark-src" </> "elm-package"]
            cabal ["install"]

        createDirectoryIfMissing True "benchmark-results"

        -- Compile each project with the golden versions of elm-compiler, elm-make, etc.
        projects <- listDirectory "benchmark-projects"
        forM_ projects (compile Gold)

        -- Use the development version of elm-compiler. By default, use the "master"
        -- branch of the repo in which benchmarking is being run.
        inDirectory (root </> "benchmark-src/elm-compiler") $ do
            hasDevBranch <- successful <$> git ["remote", "show", "dev"]
            unless hasDevBranch (void $ git ["remote", "add", "dev", root </> ".."])
            git ["pull", "dev", "master"]

        forM_ projects (compile Test)

        reportResults

-- Compile an Elm project using the Elm compiler.
compile :: Version -> FilePath -> IO ()
compile version project = do
    root <- getCurrentDirectory
    setCurrentDirectory ("benchmark-projects" </> project) 
    
    -- Remove the build artifacts so that the full project is built each
    -- time we run benchmarking. This ensures that the results of subsequent
    -- benchmarking runs are comparable.
    elmStuffExists <- doesDirectoryExist "elm-stuff/build-artifacts"
    when elmStuffExists (removeDirectoryRecursive "elm-stuff/build-artifacts")

    -- The -p flag turns profiling on.
    let elmMake = rawSystem (root </> "benchmark-src/elm-make/.cabal-sandbox/bin/elm-make")
    elmMake ["+RTS", "-p"] 

    -- Profiling should produce a file called elm-make.prof.
    copyFile "elm-make.prof" (root </> "benchmark-results" </> (project ++ "." ++ show version ++ ".prof"))

    -- reset
    setCurrentDirectory root

reportResults :: IO ()
reportResults = do
    let resultFilename = "benchmark-results" </> ("elm-todomvc" ++ "." ++ show Gold ++ ".prof")
    testResults <- Text.readFile resultFilename

    case parseOnly timeAllocProfile testResults of
        Right profile -> putStrLn . show . extractCostCentres $ profile
        Left error -> putStrLn $ "Error parsing profiling results from " ++ resultFilename ++ ": " ++ error

extractCostCentres :: TimeAllocProfile -> [(Text, Maybe CostCentre)]
extractCostCentres tree = 
        map (\name -> (name, findCostCentre name)) costCentreNames
    where 
        findCostCentre :: Text -> Maybe CostCentre
        findCostCentre name = find ((== name) . costCentreName)
            $ costCentreNodes (profileCostCentreTree tree)
    

-- Fetch and prepare a repository containing some component of the Elm Platform.
makeSrcRepo :: String -> IO ()
makeSrcRepo projectName = do
    root <- getCurrentDirectory

    projectExists <- doesDirectoryExist $ "benchmark-src" </> projectName
    unless projectExists $ do
        git [ "clone", "https://github.com/elm-lang/" ++ projectName ++ ".git", "benchmark-src" </> projectName]
        inDirectory ("benchmark-src" </> projectName) $ do
            copyFile (root </> "cabal.config.example") "cabal.config"

-- HELPER FUNCTIONS

git :: [String] -> IO ExitCode
git = rawSystem "git"

cabal :: [String] -> IO ExitCode
cabal = rawSystem "cabal" 

successful :: ExitCode -> Bool
successful = (== ExitSuccess)

listDirectory :: FilePath -> IO [FilePath]
listDirectory dir = filter (\d -> d /= "." && d /= "..")
    <$> getDirectoryContents dir

-- inDirectory changes into the specified directory, performs some IO action,
-- and then steps back out into the original directory once the action has been
-- performed.
inDirectory :: FilePath -> IO a -> IO () 
inDirectory dir action = do
    root <- getCurrentDirectory
    setCurrentDirectory dir >> action >> setCurrentDirectory root

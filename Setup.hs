{-# LANGUAGE CPP #-}
import Control.Monad
import Data.IORef

import Distribution.Simple
import Distribution.Simple.InstallDirs as I
import Distribution.Simple.LocalBuildInfo as L
import qualified Distribution.Simple.Setup as S
import qualified Distribution.Simple.Program as P
import Distribution.PackageDescription
import Distribution.Text

import System.Exit
import System.FilePath ((</>), splitDirectories)
import System.Directory
import qualified System.FilePath.Posix as Px
import System.Process


-- After Idris is built, we need to check and install the prelude and other libs

make verbosity = P.runProgramInvocation verbosity . P.simpleProgramInvocation "make"
mvn verbosity = P.runProgramInvocation verbosity . P.simpleProgramInvocation "mvn"

#ifdef mingw32_HOST_OS
-- make on mingw32 exepects unix style separators
(<//>) = (Px.</>)
idrisCmd local = Px.joinPath $ splitDirectories $
                 ".." <//> buildDir local <//> "idris" <//> "idris"
#else
idrisCmd local = ".." </>  buildDir local </>  "idris" </>  "idris"
#endif

cleanStdLib verbosity
    = do make verbosity [ "-C", "lib", "clean", "IDRIS=idris" ]
         make verbosity [ "-C", "effects", "clean", "IDRIS=idris" ]

cleanJavaLib verbosity 
  = do dirty <- doesDirectoryExist ("java" </> "target")
       when dirty $ mvn verbosity [ "-f", "java/pom.xml", "clean" ]
       pomExists <- doesFileExist ("java" </> "pom.xml")
       when pomExists $ removeFile ("java" </> "pom.xml")

installStdLib pkg local verbosity copy
    = do let dirs = L.absoluteInstallDirs pkg local copy
         let idir = datadir dirs
         let icmd = idrisCmd local
         putStrLn $ "Installing libraries in " ++ idir
         make verbosity
               [ "-C", "lib", "install"
               , "TARGET=" ++ idir
               , "IDRIS=" ++ icmd
               ]
         make verbosity
               [ "-C", "effects", "install"
               , "TARGET=" ++ idir
               , "IDRIS=" ++ icmd
               ]
         let idirRts = idir </> "rts"
         putStrLn $ "Installing run time system in " ++ idirRts
         make verbosity
               [ "-C", "rts", "install"
               , "TARGET=" ++ idirRts
               , "IDRIS=" ++ icmd
               ]

installJavaLib verbosity = mvn verbosity [ "-f", "java/pom.xml", "install" ]

-- This is a hack. I don't know how to tell cabal that a data file needs
-- installing but shouldn't be in the distribution. And it won't make the
-- distribution if it's not there, so instead I just delete
-- the file after configure.

removeLibIdris local verbosity
    = do let icmd = idrisCmd local
         make verbosity
               [ "-C", "rts", "clean"
               , "IDRIS=" ++ icmd
               ]

checkStdLib local verbosity
    = do let icmd = idrisCmd local
         putStrLn $ "Building libraries..."
         make verbosity
               [ "-C", "lib", "check"
               , "IDRIS=" ++ icmd
               ]
         make verbosity
               [ "-C", "effects", "check"
               , "IDRIS=" ++ icmd
               ]
         make verbosity
               [ "-C", "rts", "check"
               , "IDRIS=" ++ icmd
               ]

checkJavaLib verbosity = mvn verbosity [ "-f", "java/pom.xml", "package" ]

noJavaFlag flags = 
  case lookup (FlagName "nojava") (S.configConfigurationsFlags flags) of
    Just True -> True
    Just False -> False
    Nothing -> False

preparePom version
    = do pomTemplate <- readFile ("java" </> "pom_template.xml")
         writeFile ("java" </> "pom.xml") (unlines . map insertVersion $ lines pomTemplate)
    where
      insertVersion "  <version></version>" = "  <version>" ++ display version ++ "</version>"
      insertVersion other = other

-- Install libraries during both copy and install
-- See http://hackage.haskell.org/trac/hackage/ticket/718
main = do
  defaultMainWithHooks $ simpleUserHooks
        { postCopy = \ _ flags pkg lbi -> do
              let verb = S.fromFlag $ S.copyVerbosity flags
              installStdLib pkg lbi verb
                                    (S.fromFlag $ S.copyDest flags)
        , postInst = \ _ flags pkg lbi -> do
              let verb = (S.fromFlag $ S.installVerbosity flags)
              installStdLib pkg lbi verb
                                    NoCopyDest
              unless (noJavaFlag $ configFlags lbi) (installJavaLib verb)
        , postConf  = \ _ flags _ lbi -> do
              removeLibIdris lbi (S.fromFlag $ S.configVerbosity flags)
              unless (noJavaFlag $ configFlags lbi) 
                     (preparePom . pkgVersion . package $ localPkgDescr lbi)
        , postClean = \ _ flags _ _ -> do
              let verb = S.fromFlag $ S.cleanVerbosity flags
              cleanStdLib verb
              cleanJavaLib verb
        , postBuild = \ _ flags _ lbi -> do
              let verb = S.fromFlag $ S.buildVerbosity flags
              checkStdLib lbi verb
              unless (noJavaFlag $ configFlags lbi) (checkJavaLib verb)
        }

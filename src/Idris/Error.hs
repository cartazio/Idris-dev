{-# LANGUAGE DeriveDataTypeable, CPP #-}

module Idris.Error where

import Prelude  hiding (
#if !MIN_VERSION_base(4,6,0)  
              catch
#endif              
      )

import Idris.AbsSyntax
import Idris.Delaborate

import Core.TT
import Core.Typecheck
import Core.Constraints

import System.Console.Haskeline
import System.Console.Haskeline.MonadException
import Control.Monad.State
import System.IO.Error(isUserError, ioeGetErrorString)
import Data.Char
import Data.Typeable

#if MIN_VERSION_base(4,6,0)

import qualified Control.Exception.Base as E

#endif

iucheck :: Idris ()
iucheck = do tit <- typeInType
             when (not tit) $
                do ist <- get
                   idrisCatch (tclift $ ucheck (idris_constraints ist))
                              (\e -> do let msg = show e
                                        setErrLine (getErrLine msg)
                                        iputStrLn msg)

report :: IOError -> String
report e
    | isUserError e = ioeGetErrorString e 
    | otherwise     = show e

idrisCatch :: Idris a -> (SomeException -> Idris a) -> Idris a
idrisCatch a f = catch a f 

data IdrisErr = IErr String
    deriving Typeable

instance Show IdrisErr where
    show (IErr s) = s

instance Exception IdrisErr

ifail :: String -> Idris ()
ifail str = throwIO (IErr str)

tclift :: TC a -> Idris a
tclift tc = case tc of
               OK v -> return v
               Error err -> do i <- get
                               case err of
                                  At (FC f l) e -> setErrLine l
                                  _ -> return ()
                               throwIO (IErr $ pshow i err)

getErrLine str 
  = case span (/=':') str of
      (_, ':':rest) -> case span isDigit rest of
        ([], _) -> 0
        (num, _) -> read num
      _ -> 0


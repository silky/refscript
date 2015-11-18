{-# LANGUAGE ScopedTypeVariables #-}

-- | This module contains Haskell variables representing globally visible
-- names for files, paths, extensions.


module Language.Nano.Files (
  -- * Hardwired paths
    getPreludeJSONPath
  , getPreludeTSPath
  , getDomJSONPath
  , getDomTSPath
  , getIncludePath
  )
  where

import           Paths_RefScript
import           System.FilePath

getPreludeJSONPath = getDataFileName "include/prelude.json"
getPreludeTSPath   = getDataFileName "include/prelude.ts"

getDomJSONPath = getDataFileName "include/dom.json"
getDomTSPath   = getDataFileName "include/dom.ts"

getIncludePath :: FilePath -> IO FilePath
getIncludePath f   = getDataFileName $ "include" </> f

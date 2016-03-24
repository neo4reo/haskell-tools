{-# LANGUAGE FlexibleInstances
           , DeriveDataTypeable
           , TemplateHaskell
           #-}
module Language.Haskell.Tools.AnnTrf.SourceTemplate where

import Data.Data
import Data.String
import Control.Reference
import SrcLoc

data SourceTemplateElem 
  = TextElem String 
  | ChildElem
  | OptionalChildElem { _srcTmpBefore :: String
                      , _srcTmpAfter :: String
                      }
  | ChildListElem { _srcTmpDefaultSeparator :: String
                  , _srcTmpSeparators :: [String] 
                  }
     deriving (Eq, Ord, Data)

-- | A pattern that controls how the original source code can be
-- retrieved from the AST. A source template is assigned to each node.
-- It has holes where the content of an other node should be printed.
data SourceTemplate = SourceTemplate { _sourceTemplateRange :: SrcSpan
                                     , _sourceTemplateElems :: [SourceTemplateElem] 
                                     } deriving Data 

makeReferences ''SourceTemplate
      
instance Show SourceTemplateElem where
  show (TextElem s) = s
  show (ChildElem) = "«.»"
  show (OptionalChildElem _ _) = "«?»"
  show (ChildListElem _ _) = "«*»"

instance Show SourceTemplate where
  show (SourceTemplate rng sp) = concatMap show sp
  
-- * Creating source templates
  
class TemplateAnnot annot where
  fromTemplate :: SourceTemplate -> annot
  getTemplate :: annot -> SourceTemplate
  
instance IsString SourceTemplate where
  fromString s = SourceTemplate noSrcSpan [TextElem s]
     
child :: SourceTemplate
child = SourceTemplate noSrcSpan [ChildElem]

opt :: SourceTemplate
opt = SourceTemplate noSrcSpan [OptionalChildElem "" ""]

optBefore :: String -> SourceTemplate
optBefore s = SourceTemplate noSrcSpan [OptionalChildElem s ""]

optAfter :: String -> SourceTemplate
optAfter s = SourceTemplate noSrcSpan [OptionalChildElem "" s]

list :: SourceTemplate
list = SourceTemplate noSrcSpan [ChildListElem "" []]

listSep :: String -> SourceTemplate
listSep s = SourceTemplate noSrcSpan [ChildListElem s []]

(<>) :: SourceTemplate -> SourceTemplate -> SourceTemplate
SourceTemplate sp1 el1 <> SourceTemplate sp2 el2 = SourceTemplate (combineSrcSpans sp1 sp2) (el1 ++ el2)


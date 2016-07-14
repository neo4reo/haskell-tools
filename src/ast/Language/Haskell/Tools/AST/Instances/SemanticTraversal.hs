-- | Generating instances for traversing the semantic information of the Haskell Representation
{-# LANGUAGE TemplateHaskell
           #-}
module Language.Haskell.Tools.AST.Instances.SemanticTraversal where

import Language.Haskell.Tools.AST.TH.SemanticTraversal
import Control.Applicative

import Language.Haskell.Tools.AST.Modules
import Language.Haskell.Tools.AST.TH
import Language.Haskell.Tools.AST.Decls
import Language.Haskell.Tools.AST.Binds
import Language.Haskell.Tools.AST.Exprs
import Language.Haskell.Tools.AST.Stmts
import Language.Haskell.Tools.AST.Patterns
import Language.Haskell.Tools.AST.Types
import Language.Haskell.Tools.AST.Kinds
import Language.Haskell.Tools.AST.Literals
import Language.Haskell.Tools.AST.Base
import Language.Haskell.Tools.AST.Ann


-- Modules
deriveSemanticTraversal ''Module


--instance SemanticTraversal Module where
--  semaTraverse f (Module pragmas head imports decls) 
--    = Module <$> semaTraverse f pragmas <*> semaTraverse f head <*> semaTraverse f imports <*> semaTraverse f decls


deriveSemanticTraversal ''ModuleHead
deriveSemanticTraversal ''ExportSpecList
deriveSemanticTraversal ''ExportSpec
deriveSemanticTraversal ''IESpec
deriveSemanticTraversal ''SubSpec
deriveSemanticTraversal ''ModulePragma
deriveSemanticTraversal ''FilePragma
deriveSemanticTraversal ''ImportDecl
deriveSemanticTraversal ''ImportSpec
deriveSemanticTraversal ''ImportQualified
deriveSemanticTraversal ''ImportSource
deriveSemanticTraversal ''ImportSafe
deriveSemanticTraversal ''TypeNamespace
deriveSemanticTraversal ''ImportRenaming

-- Declarations
deriveSemanticTraversal ''Decl
deriveSemanticTraversal ''ClassBody
deriveSemanticTraversal ''ClassElement
deriveSemanticTraversal ''DeclHead
deriveSemanticTraversal ''InstBody
deriveSemanticTraversal ''InstBodyDecl
deriveSemanticTraversal ''GadtConDecl
deriveSemanticTraversal ''GadtConType
deriveSemanticTraversal ''GadtField
deriveSemanticTraversal ''FunDeps
deriveSemanticTraversal ''FunDep
deriveSemanticTraversal ''ConDecl
deriveSemanticTraversal ''FieldDecl
deriveSemanticTraversal ''Deriving
deriveSemanticTraversal ''InstanceRule
deriveSemanticTraversal ''InstanceHead
deriveSemanticTraversal ''TypeEqn
deriveSemanticTraversal ''KindConstraint
deriveSemanticTraversal ''TyVar
deriveSemanticTraversal ''Type
deriveSemanticTraversal ''Kind
deriveSemanticTraversal ''Context
deriveSemanticTraversal ''Assertion
deriveSemanticTraversal ''Expr
deriveSemanticTraversal ''CompStmt
deriveSemanticTraversal ''ValueBind
deriveSemanticTraversal ''Pattern
deriveSemanticTraversal ''PatternField
deriveSemanticTraversal ''Splice
deriveSemanticTraversal ''QQString
deriveSemanticTraversal ''Match
deriveSemanticTraversal ''Rhs
deriveSemanticTraversal ''GuardedRhs
deriveSemanticTraversal ''FieldUpdate
deriveSemanticTraversal ''Bracket
deriveSemanticTraversal ''TopLevelPragma
deriveSemanticTraversal ''Rule
deriveSemanticTraversal ''AnnotationSubject
deriveSemanticTraversal ''MinimalFormula
deriveSemanticTraversal ''ExprPragma
deriveSemanticTraversal ''SourceRange
deriveSemanticTraversal ''Number
deriveSemanticTraversal ''QuasiQuote
deriveSemanticTraversal ''RhsGuard
deriveSemanticTraversal ''LocalBind
deriveSemanticTraversal ''LocalBinds
deriveSemanticTraversal ''FixitySignature
deriveSemanticTraversal ''TypeSignature
deriveSemanticTraversal ''ListCompBody
deriveSemanticTraversal ''TupSecElem
deriveSemanticTraversal ''TypeFamily
deriveSemanticTraversal ''TypeFamilySpec
deriveSemanticTraversal ''InjectivityAnn
deriveSemanticTraversal ''PatternSynonym
deriveSemanticTraversal ''PatSynRhs
deriveSemanticTraversal ''PatSynLhs
deriveSemanticTraversal ''PatSynWhere
deriveSemanticTraversal ''PatternTypeSignature
deriveSemanticTraversal ''Role
deriveSemanticTraversal ''Cmd
deriveSemanticTraversal ''LanguageExtension
deriveSemanticTraversal ''MatchLhs
deriveSemanticTraversal ''Stmt'
deriveSemanticTraversal ''Alt'
deriveSemanticTraversal ''CaseRhs'
deriveSemanticTraversal ''GuardedCaseRhs'

-- Literal
deriveSemanticTraversal ''Literal
deriveSemanticTraversal ''Promoted

-- Base
deriveSemanticTraversal ''Operator
deriveSemanticTraversal ''Name
deriveSemanticTraversal ''SimpleName
deriveSemanticTraversal ''ModuleName
deriveSemanticTraversal ''UnqualName
deriveSemanticTraversal ''StringNode
deriveSemanticTraversal ''DataOrNewtypeKeyword
deriveSemanticTraversal ''DoKind
deriveSemanticTraversal ''TypeKeyword
deriveSemanticTraversal ''OverlapPragma
deriveSemanticTraversal ''CallConv
deriveSemanticTraversal ''ArrowAppl
deriveSemanticTraversal ''Safety
deriveSemanticTraversal ''ConlikeAnnot
deriveSemanticTraversal ''Assoc
deriveSemanticTraversal ''Precedence
deriveSemanticTraversal ''LineNumber
deriveSemanticTraversal ''PhaseControl
deriveSemanticTraversal ''PhaseNumber
deriveSemanticTraversal ''PhaseInvert

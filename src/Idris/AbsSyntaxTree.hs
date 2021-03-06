{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, DeriveFunctor,
             TypeSynonymInstances, PatternGuards #-}

module Idris.AbsSyntaxTree where

import Core.TT
import Core.Evaluate
import Core.Elaborate hiding (Tactic(..))
import Core.Typecheck
import RTS.SC
import Util.Pretty

import Paths_idris

import System.Console.Haskeline

import Control.Monad.State

import Data.List
import Data.Char
import Data.Either

import Debug.Trace

import qualified Epic.Epic as E

data IOption = IOption { opt_logLevel :: Int,
                         opt_typecase :: Bool,
                         opt_typeintype :: Bool,
                         opt_coverage :: Bool,
                         opt_showimp  :: Bool,
                         opt_errContext :: Bool,
                         opt_repl     :: Bool,
                         opt_verbose  :: Bool,
                         opt_ibcsubdir :: FilePath,
                         opt_importdirs :: [FilePath]
                       }
    deriving (Show, Eq)

defaultOpts = IOption 0 False False True False False True True "" []

-- TODO: Add 'module data' to IState, which can be saved out and reloaded quickly (i.e
-- without typechecking).
-- This will include all the functions and data declarations, plus fixity declarations
-- and syntax macros.

data IState = IState { tt_ctxt :: Context,
                       idris_constraints :: [(UConstraint, FC)],
                       idris_infixes :: [FixDecl],
                       idris_implicits :: Ctxt [PArg],
                       idris_statics :: Ctxt [Bool],
                       idris_classes :: Ctxt ClassInfo,
                       idris_dsls :: Ctxt DSL,
                       idris_optimisation :: Ctxt OptInfo, 
                       idris_datatypes :: Ctxt TypeInfo,
                       idris_patdefs :: Ctxt [([Name], Term, Term)], -- not exported
                       idris_flags :: Ctxt [FnOpt],
                       idris_callgraph :: Ctxt [Name],
                       idris_calledgraph :: Ctxt [Name],
                       idris_totcheck :: [(FC, Name)],
                       idris_log :: String,
                       idris_options :: IOption,
                       idris_name :: Int,
                       idris_metavars :: [Name],
                       syntax_rules :: [Syntax],
                       syntax_keywords :: [String],
                       imported :: [FilePath],
                       idris_prims :: [(Name, ([E.Name], E.Term))],
                       idris_scprims :: Prims,
                       idris_objs :: [FilePath],
                       idris_libs :: [String],
                       idris_hdrs :: [String],
                       last_proof :: Maybe (Name, [String]),
                       errLine :: Maybe Int,
                       lastParse :: Maybe Name, 
                       indent_stack :: [Int],
                       brace_stack :: [Maybe Int],
                       hide_list :: [(Name, Maybe Accessibility)],
                       default_access :: Accessibility,
                       ibc_write :: [IBCWrite],
                       compiled_so :: Maybe String
                     }

primDefs = [UN "unsafePerformIO", UN "mkLazyForeign", UN "mkForeign", UN "FalseElim"]
             
-- information that needs writing for the current module's .ibc file
data IBCWrite = IBCFix FixDecl
              | IBCImp Name
              | IBCStatic Name
              | IBCClass Name
              | IBCInstance Bool Name Name
              | IBCDSL Name
              | IBCData Name
              | IBCOpt Name
              | IBCSyntax Syntax
              | IBCKeyword String
              | IBCImport FilePath
              | IBCObj FilePath
              | IBCLib String
              | IBCHeader String
              | IBCAccess Name Accessibility
              | IBCTotal Name Totality
              | IBCFlags Name [FnOpt]
              | IBCCG Name
              | IBCDef Name -- i.e. main context
  deriving Show

idrisInit = IState initContext [] [] emptyContext emptyContext emptyContext
                   emptyContext emptyContext emptyContext emptyContext 
                   emptyContext emptyContext emptyContext
                   [] "" defaultOpts 6 [] [] [] [] [] [] [] [] []
                   Nothing Nothing Nothing [] [] [] Hidden [] Nothing

-- The monad for the main REPL - reading and processing files and updating 
-- global state (hence the IO inner monad).
type Idris = StateT IState (InputT IO)

-- Commands in the REPL

data Command = Quit   | Help | Eval PTerm | Check PTerm | TotCheck Name
             | Reload | Edit
             | Compile String | Execute | ExecVal PTerm
             | NewCompile String
             | Metavars    | Prove Name | AddProof | Universes
             | TTShell 
             | LogLvl Int | Spec PTerm | HNF PTerm | Defn Name 
             | Info Name  | DebugInfo Name
             | Search PTerm
             | SetOpt Opt | UnsetOpt Opt
             | NOP

data Opt = Filename String
         | Ver
         | Usage
         | ShowLibs
         | ShowIncs
         | NoPrelude
         | NoREPL
         | OLogging Int
         | Output String
         | NewOutput String
         | TypeCase
         | TypeInType
         | NoCoverage 
         | ErrContext 
         | ShowImpl
         | Verbose
         | IBCSubDir String
         | ImportDir String
         | BCAsm String
         | FOVM String
    deriving Eq


-- Parsed declarations

data Fixity = Infixl { prec :: Int } 
            | Infixr { prec :: Int }
            | InfixN { prec :: Int } 
            | PrefixN { prec :: Int }
    deriving Eq
{-! 
deriving instance Binary Fixity 
!-}

instance Show Fixity where
    show (Infixl i) = "infixl " ++ show i
    show (Infixr i) = "infixr " ++ show i
    show (InfixN i) = "infix " ++ show i
    show (PrefixN i) = "prefix " ++ show i

data FixDecl = Fix Fixity String 
    deriving (Show, Eq)
{-! 
deriving instance Binary FixDecl 
!-}

instance Ord FixDecl where
    compare (Fix x _) (Fix y _) = compare (prec x) (prec y)


data Static = Static | Dynamic
  deriving (Show, Eq)
{-! 
deriving instance Binary Static 
!-}

-- Mark bindings with their explicitness, and laziness
data Plicity = Imp { plazy :: Bool,
                     pstatic :: Static }
             | Exp { plazy :: Bool,
                     pstatic :: Static }
             | Constraint { plazy :: Bool,
                            pstatic :: Static }
             | TacImp { plazy :: Bool,
                        pstatic :: Static,
                        pscript :: PTerm }
  deriving (Show, Eq)

{-!
deriving instance Binary Plicity 
!-}

impl = Imp False Dynamic
expl = Exp False Dynamic
constraint = Constraint False Dynamic
tacimpl = TacImp False Dynamic

data FnOpt = Inlinable | TotalFn | AssertTotal | TCGen
           | CExport String    -- export, with a C name
           | Specialise [Name] -- specialise it, freeze these names
    deriving (Show, Eq)
{-!
deriving instance Binary FnOpt
!-}

type FnOpts = [FnOpt]

inlinable :: FnOpts -> Bool
inlinable = elem Inlinable

data PDecl' t = PFix     FC Fixity [String] -- fixity declaration
              | PTy      SyntaxInfo FC FnOpts Name t   -- type declaration
              | PClauses FC FnOpts Name [PClause' t]   -- pattern clause
              | PData    SyntaxInfo FC (PData' t)      -- data declaration
              | PParams  FC [(Name, t)] [PDecl' t] -- params block
              | PNamespace String [PDecl' t] -- new namespace
              | PRecord  SyntaxInfo FC Name t Name t     -- record declaration
              | PClass   SyntaxInfo FC 
                         [t] -- constraints
                         Name
                         [(Name, t)] -- parameters
                         [PDecl' t] -- declarations
              | PInstance SyntaxInfo FC [t] -- constraints
                                        Name -- class
                                        [t] -- parameters
                                        t -- full instance type
                                        (Maybe Name) -- explicit name
                                        [PDecl' t]
              | PDSL     Name (DSL' t)
              | PSyntax  FC Syntax
              | PDirective (Idris ())
    deriving Functor
{-!
deriving instance Binary PDecl'
!-}

data PClause' t = PClause  FC Name t [t] t [PDecl' t]
                | PWith    FC Name t [t] t [PDecl' t]
                | PClauseR FC        [t] t [PDecl' t]
                | PWithR   FC        [t] t [PDecl' t]
    deriving Functor
{-!
deriving instance Binary PClause'
!-}

data PData' t  = PDatadecl { d_name :: Name,
                             d_tcon :: t,
                             d_cons :: [(Name, t, FC)] }
    deriving Functor
{-!
deriving instance Binary PData'
!-}

-- Handy to get a free function for applying PTerm -> PTerm functions
-- across a program, by deriving Functor

type PDecl   = PDecl' PTerm
type PData   = PData' PTerm
type PClause = PClause' PTerm 

-- get all the names declared in a decl

declared :: PDecl -> [Name]
declared (PFix _ _ _) = []
declared (PTy _ _ _ n t) = [n]
declared (PClauses _ _ n _) = [] -- not a declaration
declared (PData _ _ (PDatadecl n _ ts)) = n : map fstt ts
   where fstt (a, _, _) = a
declared (PParams _ _ ds) = concatMap declared ds
declared (PNamespace _ ds) = concatMap declared ds
-- declared (PImport _) = []

defined :: PDecl -> [Name]
defined (PFix _ _ _) = []
defined (PTy _ _ _ n t) = []
defined (PClauses _ _ n _) = [n] -- not a declaration
defined (PData _ _ (PDatadecl n _ ts)) = n : map fstt ts
   where fstt (a, _, _) = a
defined (PParams _ _ ds) = concatMap defined ds
defined (PNamespace _ ds) = concatMap defined ds
-- declared (PImport _) = []

updateN :: [(Name, Name)] -> Name -> Name
updateN ns n | Just n' <- lookup n ns = n'
updateN _  n = n

updateNs :: [(Name, Name)] -> PTerm -> PTerm
updateNs [] t = t
updateNs ns t = mapPT updateRef t
  where updateRef (PRef fc f) = PRef fc (updateN ns f) 
        updateRef t = t

-- updateDNs :: [(Name, Name)] -> PDecl -> PDecl
-- updateDNs [] t = t
-- updateDNs ns (PTy s f n t)    | Just n' <- lookup n ns = PTy s f n' t
-- updateDNs ns (PClauses f n c) | Just n' <- lookup n ns = PClauses f n' (map updateCNs c)
--   where updateCNs ns (PClause n l ts r ds) 
--             = PClause (updateN ns n) (fmap (updateNs ns) l)
--                                      (map (fmap (updateNs ns)) ts)
--                                      (fmap (updateNs ns) r)
--                                      (map (updateDNs ns) ds)
-- updateDNs ns c = c

-- High level language terms

data PTerm = PQuote Raw
           | PRef FC Name
           | PLam Name PTerm PTerm
           | PPi  Plicity Name PTerm PTerm
           | PLet Name PTerm PTerm PTerm 
           | PTyped PTerm PTerm -- term with explicit type
           | PApp FC PTerm [PArg]
           | PCase FC PTerm [(PTerm, PTerm)]
           | PTrue FC
           | PFalse FC
           | PRefl FC
           | PResolveTC FC
           | PEq FC PTerm PTerm
           | PPair FC PTerm PTerm
           | PDPair FC PTerm PTerm PTerm
           | PAlternative Bool [PTerm] -- True if only one may work
           | PHidden PTerm -- irrelevant or hidden pattern
           | PSet
           | PConstant Const
           | Placeholder
           | PDoBlock [PDo]
           | PIdiom FC PTerm
           | PReturn FC
           | PMetavar Name
           | PProof [PTactic]
           | PTactics [PTactic] -- as PProof, but no auto solving
           | PElabError Err -- error to report on elaboration
           | PImpossible -- special case for declaring when an LHS can't typecheck
    deriving Eq
{-! 
deriving instance Binary PTerm 
!-}

mapPT :: (PTerm -> PTerm) -> PTerm -> PTerm
mapPT f t = f (mpt t) where
  mpt (PLam n t s) = PLam n (mapPT f t) (mapPT f s)
  mpt (PPi p n t s) = PPi p n (mapPT f t) (mapPT f s)
  mpt (PLet n ty v s) = PLet n (mapPT f ty) (mapPT f v) (mapPT f s)
  mpt (PApp fc t as) = PApp fc (mapPT f t) (map (fmap (mapPT f)) as)
  mpt (PCase fc c os) = PCase fc (mapPT f c) (map (pmap (mapPT f)) os)
  mpt (PEq fc l r) = PEq fc (mapPT f l) (mapPT f r)
  mpt (PTyped l r) = PTyped (mapPT f l) (mapPT f r)
  mpt (PPair fc l r) = PPair fc (mapPT f l) (mapPT f r)
  mpt (PDPair fc l t r) = PDPair fc (mapPT f l) (mapPT f t) (mapPT f r)
  mpt (PAlternative a as) = PAlternative a (map (mapPT f) as)
  mpt (PHidden t) = PHidden (mapPT f t)
  mpt (PDoBlock ds) = PDoBlock (map (fmap (mapPT f)) ds)
  mpt (PProof ts) = PProof (map (fmap (mapPT f)) ts)
  mpt (PTactics ts) = PTactics (map (fmap (mapPT f)) ts)
  mpt x = x


data PTactic' t = Intro [Name] | Intros | Focus Name
                | Refine Name [Bool] | Rewrite t | LetTac Name t
                | Exact t | Compute | Trivial
                | Solve
                | Attack
                | ProofState | ProofTerm | Undo
                | Try (PTactic' t) (PTactic' t)
                | TSeq (PTactic' t) (PTactic' t)
                | Qed | Abandon
    deriving (Show, Eq, Functor)
{-! 
deriving instance Binary PTactic' 
!-}

instance Sized a => Sized (PTactic' a) where
  size (Intro nms) = 1 + size nms
  size Intros = 1
  size (Focus nm) = 1 + size nm
  size (Refine nm bs) = 1 + size nm + length bs
  size (Rewrite t) = 1 + size t
  size (LetTac nm t) = 1 + size nm + size t
  size (Exact t) = 1 + size t
  size Compute = 1
  size Trivial = 1
  size Solve = 1
  size Attack = 1
  size ProofState = 1
  size ProofTerm = 1
  size Undo = 1
  size (Try l r) = 1 + size l + size r
  size (TSeq l r) = 1 + size l + size r
  size Qed = 1
  size Abandon = 1

type PTactic = PTactic' PTerm

data PDo' t = DoExp  FC t
            | DoBind FC Name t
            | DoBindP FC t t
            | DoLet  FC Name t t
            | DoLetP FC t t
    deriving (Eq, Functor)
{-! 
deriving instance Binary PDo' 
!-}

instance Sized a => Sized (PDo' a) where
  size (DoExp fc t) = 1 + size fc + size t
  size (DoBind fc nm t) = 1 + size fc + size nm + size t
  size (DoBindP fc l r) = 1 + size fc + size l + size r
  size (DoLet fc nm l r) = 1 + size fc + size nm + size l + size r
  size (DoLetP fc l r) = 1 + size fc + size l + size r

type PDo = PDo' PTerm

-- The priority gives a hint as to elaboration order. Best to elaborate
-- things early which will help give a more concrete type to other
-- variables, e.g. a before (interpTy a).

data PArg' t = PImp { priority :: Int, 
                      lazyarg :: Bool, pname :: Name, getTm :: t }
             | PExp { priority :: Int,
                      lazyarg :: Bool, getTm :: t }
             | PConstraint { priority :: Int,
                             lazyarg :: Bool, getTm :: t }
             | PTacImplicit { priority :: Int,
                              lazyarg :: Bool, pname :: Name, 
                              getScript :: t,
                              getTm :: t }
    deriving (Show, Eq, Functor)

instance Sized a => Sized (PArg' a) where
  size (PImp p l nm trm) = 1 + size nm + size trm
  size (PExp p l trm) = 1 + size trm
  size (PConstraint p l trm) = 1 + size trm
  size (PTacImplicit p l nm scr trm) = 1 + size nm + size scr + size trm

{-! 
deriving instance Binary PArg' 
!-}

pimp = PImp 0 True
pexp = PExp 0 False
pconst = PConstraint 0 False
ptacimp = PTacImplicit 0 True

type PArg = PArg' PTerm

-- Type class data

data ClassInfo = CI { instanceName :: Name,
                      class_methods :: [(Name, (FnOpts, PTerm))],
                      class_defaults :: [(Name, (Name, PDecl))], -- method name -> default impl
                      class_params :: [Name],
                      class_instances :: [Name] }
    deriving Show
{-! 
deriving instance Binary ClassInfo 
!-}

data OptInfo = Optimise { collapsible :: Bool,
                          forceable :: [Int], -- argument positions
                          recursive :: [Int] }
    deriving Show
{-! 
deriving instance Binary OptInfo 
!-}


data TypeInfo = TI { con_names :: [Name] }
    deriving Show
{-!
deriving instance Binary TypeInfo
!-}

-- Syntactic sugar info 

data DSL' t = DSL { dsl_bind    :: t,
                    dsl_return  :: t,
                    dsl_apply   :: t,
                    dsl_pure    :: t,
                    dsl_var     :: Maybe t,
                    index_first :: Maybe t,
                    index_next  :: Maybe t,
                    dsl_lambda  :: Maybe t,
                    dsl_let     :: Maybe t
                  }
    deriving (Show, Functor)
{-!
deriving instance Binary DSL'
!-}

type DSL = DSL' PTerm

data SynContext = PatternSyntax | TermSyntax | AnySyntax
    deriving Show
{-! 
deriving instance Binary SynContext 
!-}

data Syntax = Rule [SSymbol] PTerm SynContext
    deriving Show
{-! 
deriving instance Binary Syntax 
!-}

data SSymbol = Keyword Name
             | Symbol String
             | Binding Name
             | Expr Name
             | SimpleExpr Name
    deriving Show
{-! 
deriving instance Binary SSymbol 
!-}

initDSL = DSL (PRef f (UN ">>=")) 
              (PRef f (UN "return"))
              (PRef f (UN "<$>"))
              (PRef f (UN "pure"))
              Nothing
              Nothing
              Nothing
              Nothing
              Nothing
  where f = FC "(builtin)" 0

data SyntaxInfo = Syn { using :: [(Name, PTerm)],
                        syn_params :: [(Name, PTerm)],
                        syn_namespace :: [String],
                        no_imp :: [Name],
                        decoration :: Name -> Name,
                        inPattern :: Bool,
                        implicitAllowed :: Bool,
                        dsl_info :: DSL }
    deriving Show
{-!
deriving instance Binary SyntaxInfo
!-}

defaultSyntax = Syn [] [] [] [] id False False initDSL

expandNS :: SyntaxInfo -> Name -> Name
expandNS syn n@(NS _ _) = n
expandNS syn n = case syn_namespace syn of
                        [] -> n
                        xs -> NS n xs


--- Pretty printing declarations and terms

instance Show PTerm where
    show tm = showImp False tm

instance Pretty PTerm where
  pretty = prettyImp False

instance Show PDecl where
    show d = showDeclImp False d

instance Show PClause where
    show c = showCImp True c

instance Show PData where
    show d = showDImp False d

showDeclImp _ (PFix _ f ops) = show f ++ " " ++ showSep ", " ops
showDeclImp t (PTy _ _ _ n ty) = show n ++ " : " ++ showImp t ty
showDeclImp _ (PClauses _ _ n c) = showSep "\n" (map show c)
showDeclImp _ (PData _ _ d) = show d

showCImp :: Bool -> PClause -> String
showCImp impl (PClause _ n l ws r w) 
   = showImp impl l ++ showWs ws ++ " = " ++ showImp impl r
             ++ " where " ++ show w 
  where
    showWs [] = ""
    showWs (x : xs) = " | " ++ showImp impl x ++ showWs xs
showCImp impl (PWith _ n l ws r w) 
   = showImp impl l ++ showWs ws ++ " with " ++ showImp impl r
             ++ " { " ++ show w ++ " } " 
  where
    showWs [] = ""
    showWs (x : xs) = " | " ++ showImp impl x ++ showWs xs


showDImp :: Bool -> PData -> String
showDImp impl (PDatadecl n ty cons) 
   = "data " ++ show n ++ " : " ++ showImp impl ty ++ " where\n\t"
     ++ showSep "\n\t| " 
            (map (\ (n, t, _) -> show n ++ " : " ++ showImp impl t) cons)

getImps :: [PArg] -> [(Name, PTerm)]
getImps [] = []
getImps (PImp _ _ n tm : xs) = (n, tm) : getImps xs
getImps (_ : xs) = getImps xs

getExps :: [PArg] -> [PTerm]
getExps [] = []
getExps (PExp _ _ tm : xs) = tm : getExps xs
getExps (_ : xs) = getExps xs

getConsts :: [PArg] -> [PTerm]
getConsts [] = []
getConsts (PConstraint _ _ tm : xs) = tm : getConsts xs
getConsts (_ : xs) = getConsts xs

getAll :: [PArg] -> [PTerm]
getAll = map getTm 

prettyImp :: Bool -> PTerm -> Doc
prettyImp impl = prettySe 10
  where
    prettySe p (PQuote r) =
      if size r > breakingSize then
        text "![" $$ pretty r <> text "]"
      else
        text "![" <> pretty r <> text "]"
    prettySe p (PRef fc n) =
      if impl then
        pretty n
      else
        prettyBasic n
      where
        prettyBasic n@(UN _) = pretty n
        prettyBasic (MN _ s) = text s
        prettyBasic (NS n s) = (foldr (<>) empty (intersperse (text ".") (map text $ reverse s))) <> prettyBasic n
    prettySe p (PLam n ty sc) =
      bracket p 2 $
        if size sc > breakingSize then
          text "λ" <> pretty n <+> text "=>" $+$ pretty sc
        else
          text "λ" <> pretty n <+> text "=>" <+> pretty sc
    prettySe p (PLet n ty v sc) =
      bracket p 2 $
        if size sc > breakingSize then
          text "let" <+> pretty n <+> text "=" <+> prettySe 10 v <+> text "in" $+$
            nest nestingSize (prettySe 10 sc)
        else
          text "let" <+> pretty n <+> text "=" <+> prettySe 10 v <+> text "in" <+>
            prettySe 10 sc
    prettySe p (PPi (Exp l s) n ty sc)
      | n `elem` allNamesIn sc || impl =
          let open = if l then text "|" <> lparen else lparen in
            bracket p 2 $
              if size sc > breakingSize then
                open <> pretty n <+> colon <+> prettySe 10 ty <> rparen <+>
                  st <+> text "->" $+$ prettySe 10 sc
              else
                open <> pretty n <+> colon <+> prettySe 10 ty <> rparen <+>
                  st <+> text "->" <+> prettySe 10 sc
      | otherwise                      =
          bracket p 2 $
            if size sc > breakingSize then
              prettySe 0 ty <+> st <+> text "->" $+$ prettySe 10 sc
            else
              prettySe 0 ty <+> st <+> text "->" <+> prettySe 10 sc
      where
        st =
          case s of
            Static -> text "[static]"
            _      -> empty
    prettySe p (PPi (Imp l s) n ty sc)
      | impl =
          let open = if l then text "|" <> lbrace else lbrace in
            bracket p 2 $
              if size sc > breakingSize then
                open <> pretty n <+> colon <+> prettySe 10 ty <> rbrace <+>
                  st <+> text "->" <+> prettySe 10 sc
              else
                open <> pretty n <+> colon <+> prettySe 10 ty <> rbrace <+>
                  st <+> text "->" <+> prettySe 10 sc
      | otherwise = prettySe 10 sc
      where
        st =
          case s of
            Static -> text $ "[static]"
            _      -> empty
    prettySe p (PPi (Constraint _ _) n ty sc) =
      bracket p 2 $
        if size sc > breakingSize then
          prettySe 10 ty <+> text "=>" <+> prettySe 10 sc
        else
          prettySe 10 ty <+> text "=>" $+$ prettySe 10 sc
    prettySe p (PPi (TacImp _ _ s) n ty sc) =
      bracket p 2 $
        if size sc > breakingSize then
          lbrace <> text "tacimp" <+> pretty n <+> colon <+> prettySe 10 ty <>
            rbrace <+> text "->" $+$ prettySe 10 sc
        else
          lbrace <> text "tacimp" <+> pretty n <+> colon <+> prettySe 10 ty <>
            rbrace <+> text "->" <+> prettySe 10 sc
    prettySe p (PApp _ (PRef _ f) [])
      | not impl = pretty f
    prettySe p (PApp _ (PRef _ op@(UN (f:_))) args)
      | length (getExps args) == 2 && (not impl) && (not $ isAlpha f) =
          let [l, r] = getExps args in
            bracket p 1 $
              if size r > breakingSize then
                prettySe 1 l <+> pretty op $+$ prettySe 0 r
              else
                prettySe 1 l <+> pretty op <+> prettySe 0 r
    prettySe p (PApp _ f as) =
      let args = getExps as in
        bracket p 1 $
          prettySe 1 f <+>
            if impl then
              foldl fS empty as
              -- foldr (<+>) empty $ map prettyArgS as
            else
              foldl fSe empty args
              -- foldr (<+>) empty $ map prettyArgSe args
      where
        fS l r =
          if size r > breakingSize then
            l $+$ nest nestingSize (prettyArgS r)
          else
            l <+> prettyArgS r

        fSe l r =
          if size r > breakingSize then
            l $+$ nest nestingSize (prettyArgSe r)
          else
            l <+> prettyArgSe r
    prettySe p (PCase _ scr opts) =
      text "case" <+> prettySe 10 scr <+> text "of" $+$ nest nestingSize prettyBody
      where
        prettyBody = foldr ($$) empty $ intersperse (text "|") $ map sc opts

        sc (l, r) = prettySe 10 l <+> text "=>" <+> prettySe 10 r
    prettySe p (PHidden tm) = text "." <> prettySe 0 tm
    prettySe p (PRefl _) = text "refl"
    prettySe p (PResolveTC _) = text "resolvetc"
    prettySe p (PTrue _) = text "()"
    prettySe p (PFalse _) = text "_|_"
    prettySe p (PEq _ l r) =
      bracket p 2 $
        if size r > breakingSize then
          prettySe 10 l <+> text "=" $$ nest nestingSize (prettySe 10 r)
        else
          prettySe 10 l <+> text "=" <+> prettySe 10 r
    prettySe p (PTyped l r) =
      lparen <> prettySe 10 l <+> colon <+> prettySe 10 r <> rparen
    prettySe p (PPair _ l r) =
      if size r > breakingSize then
        lparen <> prettySe 10 l <> text "," $+$
          prettySe 10 r <> rparen
      else
        lparen <> prettySe 10 l <> text "," <+> prettySe 10 r <> rparen
    prettySe p (PDPair _ l t r) =
      if size r > breakingSize then
        lparen <> prettySe 10 l <+> text "**" $+$
          prettySe 10 r <> rparen
      else
        lparen <> prettySe 10 l <+> text "**" <+> prettySe 10 r <> rparen
    prettySe p (PAlternative a as) =
      lparen <> text "|" <> prettyAs <> text "|" <> rparen
        where
          prettyAs =
            foldr (\l -> \r -> l <+> text "," <+> r) empty $ map (prettySe 10) as
    prettySe p PSet = text "Set"
    prettySe p (PConstant c) = pretty c
    -- XXX: add pretty for tactics
    prettySe p (PProof ts) =
      text "proof" <+> lbrace $+$ nest nestingSize (text . show $ ts) $+$ rbrace
    prettySe p (PTactics ts) =
      text "tactics" <+> lbrace $+$ nest nestingSize (text . show $ ts) $+$ rbrace
    prettySe p (PMetavar n) = text "?" <> pretty n
    prettySe p (PReturn f) = text "return"
    prettySe p PImpossible = text "impossible"
    prettySe p Placeholder = text "_"
    prettySe p (PDoBlock _) = text "do block pretty not implemented"
    prettySe p (PElabError s) = pretty s

    prettySe p _ = text "test"

    prettyArgS :: PArg -> Doc
    prettyArgS (PImp _ _ n tm) = prettyArgSi (n, tm)
    prettyArgS (PExp _ _ tm)   = prettyArgSe tm
    prettyArgS (PConstraint _ _ tm) = prettyArgSc tm
    prettyArgS (PTacImplicit _ _ n _ tm) = prettyArgSti (n, tm)

    prettyArgSe:: PTerm -> Doc
    prettyArgSe arg = prettySe 0 arg
    prettyArgSi (n, val) = lbrace <> pretty n <+> text "=" <+> prettySe 10 val <> rbrace
    prettyArgSc val = lbrace <> lbrace <> prettySe 10 val <> rbrace <> rbrace
    prettyArgSti (n, val) = lbrace <> text "auto" <+> pretty n <+> text "=" <+> prettySe 10 val <> rbrace

    bracket outer inner doc
      | inner > outer = lparen <> doc <> rparen
      | otherwise     = doc
        
showImp :: Bool -> PTerm -> String
showImp impl tm = se 10 tm where
    se p (PQuote r) = "![" ++ show r ++ "]"
    se p (PRef fc n) = if impl then show n -- ++ "[" ++ show fc ++ "]"
                               else showbasic n
      where showbasic n@(UN _) = show n
            showbasic (MN _ s) = s
            showbasic (NS n s) = showSep "." (reverse s) ++ "." ++ showbasic n
    se p (PLam n ty sc) = bracket p 2 $ "\\ " ++ show n ++ 
                            (if impl then " : " ++ se 10 ty else "") ++ " => " 
                            ++ se 10 sc
    se p (PLet n ty v sc) = bracket p 2 $ "let " ++ show n ++ " = " ++ se 10 v ++
                            " in " ++ se 10 sc 
    se p (PPi (Exp l s) n ty sc)
        | n `elem` allNamesIn sc || impl
                                  = bracket p 2 $
                                    if l then "|(" else "(" ++ 
                                    show n ++ " : " ++ se 10 ty ++ 
                                    ") " ++ st ++
                                    "-> " ++ se 10 sc
        | otherwise = bracket p 2 $ se 0 ty ++ " " ++ st ++ "-> " ++ se 10 sc
      where st = case s of
                    Static -> "[static] "
                    _ -> ""
    se p (PPi (Imp l s) n ty sc)
        | impl = bracket p 2 $ if l then "|{" else "{" ++ 
                               show n ++ " : " ++ se 10 ty ++ 
                               "} " ++ st ++ "-> " ++ se 10 sc
        | otherwise = se 10 sc
      where st = case s of
                    Static -> "[static] "
                    _ -> ""
    se p (PPi (Constraint _ _) n ty sc)
        = bracket p 2 $ se 10 ty ++ " => " ++ se 10 sc
    se p (PPi (TacImp _ _ s) n ty sc)
        = bracket p 2 $ "{tacimp " ++ show n ++ " : " ++ se 10 ty ++ "} -> " ++ se 10 sc
    se p (PApp _ (PRef _ f) [])
        | not impl = show f
    se p (PApp _ (PRef _ op@(UN (f:_))) args)
        | length (getExps args) == 2 && not impl && not (isAlpha f) 
            = let [l, r] = getExps args in
              bracket p 1 $ se 1 l ++ " " ++ show op ++ " " ++ se 0 r
    se p (PApp _ f as) 
        = let args = getExps as in
              bracket p 1 $ se 1 f ++ if impl then concatMap sArg as
                                              else concatMap seArg args
    se p (PCase _ scr opts) = "case " ++ se 10 scr ++ " of " ++ showSep " | " (map sc opts)
       where sc (l, r) = se 10 l ++ " => " ++ se 10 r
    se p (PHidden tm) = "." ++ se 0 tm
    se p (PRefl _) = "refl"
    se p (PResolveTC _) = "resolvetc"
    se p (PTrue _) = "()"
    se p (PFalse _) = "_|_"
    se p (PEq _ l r) = bracket p 2 $ se 10 l ++ " = " ++ se 10 r
    se p (PTyped l r) = "(" ++ se 10 l ++ " : " ++ se 10 r ++ ")"
    se p (PPair _ l r) = "(" ++ se 10 l ++ ", " ++ se 10 r ++ ")"
    se p (PDPair _ l t r) = "(" ++ se 10 l ++ " ** " ++ se 10 r ++ ")"
    se p (PAlternative a as) = "(|" ++ showSep " , " (map (se 10) as) ++ "|)"
    se p PSet = "Set"
    se p (PConstant c) = show c
    se p (PProof ts) = "proof { " ++ show ts ++ "}"
    se p (PTactics ts) = "tactics { " ++ show ts ++ "}"
    se p (PMetavar n) = "?" ++ show n
    se p (PReturn f) = "return"
    se p PImpossible = "impossible"
    se p Placeholder = "_"
    se p (PDoBlock _) = "do block show not implemented"
    se p (PElabError s) = show s
--     se p x = "Not implemented"
    sArg:: PArg -> [Char]
    sArg (PImp _ _ n tm) = siArg (n, tm)
    sArg (PExp _ _ tm) = seArg tm
    sArg (PConstraint _ _ tm) = scArg tm
    sArg (PTacImplicit _ _ n _ tm) = stiArg (n, tm)

    seArg:: PTerm -> [Char]
    seArg arg      = " " ++ se 0 arg
    siArg (n, val) = " {" ++ show n ++ " = " ++ se 10 val ++ "}"
    scArg val = " {{" ++ se 10 val ++ "}}"
    stiArg (n, val) = " {auto " ++ show n ++ " = " ++ se 10 val ++ "}"

    bracket outer inner str | inner > outer = "(" ++ str ++ ")"
                            | otherwise = str

{-
 PQuote Raw
           | PRef FC Name
           | PLam Name PTerm PTerm
           | PPi  Plicity Name PTerm PTerm
           | PLet Name PTerm PTerm PTerm 
           | PTyped PTerm PTerm -- term with explicit type
           | PApp FC PTerm [PArg]
           | PCase FC PTerm [(PTerm, PTerm)]
           | PTrue FC
           | PFalse FC
           | PRefl FC
           | PResolveTC FC
           | PEq FC PTerm PTerm
           | PPair FC PTerm PTerm
           | PDPair FC PTerm PTerm PTerm
           | PAlternative [PTerm]
           | PHidden PTerm -- irrelevant or hidden pattern
           | PSet
           | PConstant Const
           | Placeholder
           | PDoBlock [PDo]
           | PIdiom FC PTerm
           | PReturn FC
           | PMetavar Name
           | PProof [PTactic]
           | PTactics [PTactic] -- as PProof, but no auto solving
           | PElabError Err -- error to report on elaboration
           | PImpossible -- special case for declaring when an LHS can't typecheck
-}

instance Sized PTerm where
  size (PQuote rawTerm) = size rawTerm
  size (PRef fc name) = size name
  size (PLam name ty bdy) = 1 + size ty + size bdy
  size (PPi plicity name ty bdy) = 1 + size ty + size bdy
  size (PLet name ty def bdy) = 1 + size ty + size def + size bdy
  size (PTyped trm ty) = 1 + size trm + size ty
  size (PApp fc name args) = 1 + size args
  size (PCase fc trm bdy) = 1 + size trm + size bdy
  size (PTrue fc) = 1
  size (PFalse fc) = 1
  size (PRefl fc) = 1
  size (PResolveTC fc) = 1
  size (PEq fc left right) = 1 + size left + size right
  size (PPair fc left right) = 1 + size left + size right
  size (PDPair fs left ty right) = 1 + size left + size ty + size right
  size (PAlternative a alts) = 1 + size alts
  size (PHidden hidden) = size hidden
  size PSet = 1
  size (PConstant const) = 1 + size const
  size Placeholder = 1
  size (PDoBlock dos) = 1 + size dos
  size (PIdiom fc term) = 1 + size term
  size (PReturn fc) = 1
  size (PMetavar name) = 1
  size (PProof tactics) = size tactics
  size (PElabError err) = size err
  size PImpossible = 1

allNamesIn :: PTerm -> [Name]
allNamesIn tm = nub $ ni [] tm 
  where
    ni env (PRef _ n)        
        | not (n `elem` env) = [n]
    ni env (PApp _ f as)   = ni env f ++ concatMap (ni env) (map getTm as)
    ni env (PCase _ c os)  = ni env c ++ concatMap (ni env) (map snd os)
    ni env (PLam n ty sc)  = ni env ty ++ ni (n:env) sc
    ni env (PPi _ n ty sc) = ni env ty ++ ni (n:env) sc
    ni env (PHidden tm)    = ni env tm
    ni env (PEq _ l r)     = ni env l ++ ni env r
    ni env (PTyped l r)    = ni env l ++ ni env r
    ni env (PPair _ l r)   = ni env l ++ ni env r
    ni env (PDPair _ (PRef _ n) t r)  = ni env t ++ ni (n:env) r
    ni env (PDPair _ l t r)  = ni env l ++ ni env t ++ ni env r
    ni env (PAlternative a ls) = concatMap (ni env) ls
    ni env _               = []

namesIn :: [(Name, PTerm)] -> IState -> PTerm -> [Name]
namesIn uvars ist tm = nub $ ni [] tm 
  where
    ni env (PRef _ n)        
        | not (n `elem` env) 
            = case lookupTy Nothing n (tt_ctxt ist) of
                [] -> [n]
                _ -> if n `elem` (map fst uvars) then [n] else []
    ni env (PApp _ f as)   = ni env f ++ concatMap (ni env) (map getTm as)
    ni env (PCase _ c os)  = ni env c ++ concatMap (ni env) (map snd os)
    ni env (PLam n ty sc)  = ni env ty ++ ni (n:env) sc
    ni env (PPi _ n ty sc) = ni env ty ++ ni (n:env) sc
    ni env (PEq _ l r)     = ni env l ++ ni env r
    ni env (PTyped l r)    = ni env l ++ ni env r
    ni env (PPair _ l r)   = ni env l ++ ni env r
    ni env (PDPair _ (PRef _ n) t r) = ni env t ++ ni (n:env) r
    ni env (PDPair _ l t r) = ni env l ++ ni env t ++ ni env r
    ni env (PAlternative a as) = concatMap (ni env) as
    ni env (PHidden tm)    = ni env tm
    ni env _               = []

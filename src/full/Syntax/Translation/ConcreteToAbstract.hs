{-# OPTIONS -cpp -fglasgow-exts -fallow-overlapping-instances #-}

{-| Translation from "Syntax.Concrete" to "Syntax.Abstract". Involves scope analysis,
    figuring out infix operator precedences and tidying up definitions.
-}
module Syntax.Translation.ConcreteToAbstract where

import Control.Exception
import Data.Typeable

import Syntax.Concrete as C
import Syntax.Concrete.Pretty ()    -- TODO: only needed for Show for the exceptions
import Syntax.Abstract as A
import Syntax.Position
import Syntax.Common
import Syntax.Info
--import Syntax.Interface
import Syntax.Concrete.Definitions as CD
import Syntax.Concrete.Fixity
import Syntax.Scope

import Interaction.Imports

import Utils.Monad

#include "../../undefined.h"


{--------------------------------------------------------------------------
    Exceptions
 --------------------------------------------------------------------------}

data ToAbstractException
	= HigherOrderPattern C.Pattern C.Pattern
	    -- ^ the first pattern is an application and the second
	    --	 pattern is the function part (and it's not
	    --	 a constructor pattern).
	| NotAModuleExpr C.Expr
	    -- ^ The expr was used in the right hand side of an implicit module
	    --	 definition, but it wasn't of the form @m Delta@.
    deriving (Typeable, Show)

higherOrderPattern p0 p = throwDyn $ HigherOrderPattern p0 p
notAModuleExpr e	= throwDyn $ NotAModuleExpr e

instance HasRange ToAbstractException where
    getRange (HigherOrderPattern p _) = getRange p
    getRange (NotAModuleExpr e)	      = getRange e

{--------------------------------------------------------------------------
    Helpers
 --------------------------------------------------------------------------}

exprSource :: C.Expr -> ScopeM ExprInfo
exprSource e =
    do	f <- getFixityFunction
	return $ ExprSource (getRange e) (paren f e)

{--------------------------------------------------------------------------
    Translation
 --------------------------------------------------------------------------}

-- | Things that can be translated to abstract syntax are instances of this
--   class.
class ToAbstract concrete abstract | concrete -> abstract where

    toAbstract	  :: concrete -> ScopeM abstract

-- | This function should be used instead of 'toAbstract' for things that need
--   to keep track of precedences to make sure that we don't forget about it.
toAbstractCtx :: ToAbstract concrete abstract =>
		 Precedence -> concrete -> ScopeM abstract
toAbstractCtx ctx c = setContext ctx $ toAbstract c

-- | Things that can be translated to abstract syntax and in the process
--   update the scope are instances of this class.
class BindToAbstract concrete abstract | concrete -> abstract where
    bindToAbstract :: concrete -> (abstract -> ScopeM a) -> ScopeM a

instance (ToAbstract c1 a1, ToAbstract c2 a2) => ToAbstract (c1,c2) (a1,a2) where
    toAbstract (x,y) =
	(,) <$> toAbstract x <*> toAbstract y

instance (ToAbstract c1 a1, ToAbstract c2 a2, ToAbstract c3 a3) =>
	 ToAbstract (c1,c2,c3) (a1,a2,a3) where
    toAbstract (x,y,z) = flatten <$> toAbstract (x,(y,z))
	where
	    flatten (x,(y,z)) = (x,y,z)

instance ToAbstract c a => ToAbstract [c] [a] where
    toAbstract = mapM toAbstract 

instance ToAbstract c a => ToAbstract (Maybe c) (Maybe a) where
    toAbstract Nothing  = return Nothing
    toAbstract (Just x) = Just <$> toAbstract x

instance (BindToAbstract c1 a1, BindToAbstract c2 a2) => BindToAbstract (c1,c2) (a1,a2) where
    bindToAbstract (x,y) ret =
	bindToAbstract x $ \x' ->
	bindToAbstract y $ \y' ->
	ret (x',y')

instance BindToAbstract c a => BindToAbstract [c] [a] where
    bindToAbstract [] ret = ret []
    bindToAbstract (x:xs) ret =
	bindToAbstract (x,xs) $ \ (y,ys) -> ret (y:ys)

instance ToAbstract C.Expr A.Expr where

    -- Names
    toAbstract (Ident x) =
	do  qx <- resolveNameM x
	    case qx of
		VarName x'  -> return $
				Var (NameInfo
				    { bindingSite	= getRange x'
				    , concreteName	= x
				    , nameFixity	= defaultFixity
				    , nameAccess	= PrivateAccess
				    }
				   ) x'
		DefName d   ->
		    case kindOfName d of
			FunName  -> return $ Def info $ theName d
			ConName  -> return $ Con info $ theName d
		    where
			info = NameInfo { bindingSite   = getRange d
					, concreteName  = x
					, nameFixity    = fixity d
					, nameAccess    = access d
					}
		UnknownName	-> notInScope x

    -- Literals
    toAbstract (C.Lit l)    = return $ A.Lit l

    -- Meta variables
    toAbstract (C.QuestionMark r) =
	do  scope <- getScopeInfo
	    return $ A.QuestionMark $ MetaInfo { metaRange = r
					       , metaScope = scope
					       }
    toAbstract (C.Underscore r) =
	do  scope <- getScopeInfo
	    return $ A.Underscore $ MetaInfo { metaRange = r
					       , metaScope = scope
					       }

    -- Application
    toAbstract e@(C.App r h e1 e2) =
	do  e1'  <- toAbstractCtx FunctionCtx e1
	    e2'  <- toAbstractCtx (hiddenArgumentCtx h) e2
	    info <- exprSource e
	    return $ A.App info h e1' e2'

    -- Infix application
    toAbstract e@(C.InfixApp _ _ _) =
	do  f <- getFixityFunction
	    -- Rotating an infix application always returns an infix application.
	    let C.InfixApp e1 op e2 = rotateInfixApp f e
		fx		    = f op

	    e1'  <- toAbstractCtx (LeftOperandCtx fx) e1
	    op'  <- toAbstractCtx TopCtx $ Ident op
	    e2'  <- toAbstractCtx (RightOperandCtx fx) e2
	    info <- exprSource e
	    return $ A.App info NotHidden
			   (A.App (ExprRange $ fuseRange e1' op')
				  NotHidden op' e1'
			   ) e2'    -- infix applications are never hidden

    -- Lambda
    toAbstract e0@(C.Lam r bs e) =
	bindToAbstract bs $ \ (b:bs') ->
	    do  e'   <- toAbstractCtx TopCtx e
		info <- exprSource e0
		return $ A.Lam info b $ foldr mkLam e' bs'
	where
	    mkLam b e = A.Lam (ExprRange $ fuseRange b e) b e

    -- Function types
    toAbstract e@(Fun r h e1 e2) =
	do  e1'  <- toAbstractCtx FunctionSpaceDomainCtx e1
	    e2'  <- toAbstractCtx TopCtx e2
	    info <- exprSource e
	    return $ A.Pi info
			  (A.TypedBinding (getRange e1) h [noName] e1')
			  e2'

    toAbstract e0@(C.Pi b e) =
	bindToAbstract b $ \b' ->
	do  e'	 <- toAbstractCtx TopCtx e
	    info <- exprSource e0
	    return $ A.Pi info b' e'

    -- Sorts
    toAbstract e@(C.Set _)    = flip A.Set 0 <$> exprSource e
    toAbstract e@(C.SetN _ n) = flip A.Set n <$> exprSource e
    toAbstract e@(C.Prop _)   = A.Prop <$> exprSource e

    -- Let
    toAbstract e0@(C.Let _ ds e) =
	bindToAbstract ds $ \ds' ->
	do  e'   <- toAbstractCtx TopCtx e
	    info <- exprSource e0
	    return $ A.Let info ds' e'

    -- Parenthesis
    toAbstract (C.Paren _ e) = toAbstractCtx TopCtx e
	-- You could imagine remembering parenthesis. I don't really see the
	-- point though.

instance BindToAbstract C.LamBinding A.LamBinding where
    bindToAbstract (C.DomainFree h x) ret =
	bindVariable x $ ret (A.DomainFree h x)
    bindToAbstract (C.DomainFull tb) ret =
	bindToAbstract tb $ \tb' -> ret (A.DomainFull tb')

instance BindToAbstract C.TypedBinding A.TypedBinding where
    bindToAbstract (C.TypedBinding r h xs t) ret =
	do  t' <- toAbstractCtx TopCtx t
	    bindVariables xs $ ret (A.TypedBinding r h xs t')

-- Note: only for top level modules!
instance ToAbstract C.Declaration (A.Declaration, ScopeInfo) where
    toAbstract (C.Module r x@(Qual _ _) tel ds) =
	insideModule x $
	bindToAbstract (tel,ds) $ \(tel',ds') ->    -- order matter!
	    do	scope <- getScopeInfo
		return (A.Module info x tel' ds', scope)
	where
	    info = mkRangedDefInfo defaultFixity PublicAccess r
			-- We could save the concrete module here but
			-- seems a bit over-kill.
    toAbstract _ = __IMPOSSIBLE__   -- only for top-level modules.

instance BindToAbstract [C.Declaration] [A.Declaration] where
    bindToAbstract ds = bindToAbstract (niceDeclarations ds)

instance BindToAbstract [NiceDeclaration] [A.Declaration] where
    bindToAbstract [] ret = ret []
    bindToAbstract (x:xs) ret =
	bindToAbstract (x,xs) $ \ (y,ys) -> ret (y ++ ys)

-- Only constructor names are bound by definitions.
instance BindToAbstract NiceDefinition Definition where

    -- Function definitions
    bindToAbstract (CD.FunDef r ds f a x cs) ret =
	do  cs' <- toAbstract cs
	    ret $ A.FunDef (mkSourcedDefInfo f a ds) x cs'

    -- Data definitions
    bindToAbstract (CD.DataDef r f a x pars cons) ret =
	do  (pars', cons') <- bindToAbstract pars $ \pars' ->
				do  cons' <- toAbstract $ map Constr cons
				    return (pars', cons')
	    -- bring the constructor names into scope
	    bindToAbstract (map Constr cons') $ \_ ->
		ret $ A.DataDef (mkRangedDefInfo f a r) x pars' cons'

-- The only reason why we return a list is that open declarations disappears.
-- For every other declaration we get a singleton list.
instance BindToAbstract NiceDeclaration [A.Declaration] where

    -- Axiom
    bindToAbstract (CD.Axiom r f a x t) ret =
	do  t' <- toAbstractCtx TopCtx t
	    defineName a FunName f x $
		ret [A.Axiom (mkRangedDefInfo f a r) x t']
				-- we can easily reconstruct the original decl
				-- so we don't bother save it

    -- Function synonym
    bindToAbstract (CD.Synonym r f a x e wh) ret =
	do  (e',wh') <- bindToAbstract wh $ \wh' ->
			    do	e' <- toAbstractCtx TopCtx e
				return (e',wh')
	    defineName a FunName f x $
		ret [A.Synonym (mkRangedDefInfo f a r) x e' wh']

    -- Definitions (possibly mutual)
    bindToAbstract (NiceDef r cs ts ds) ret =
	bindToAbstract (ts,ds) $ \ (ts',ds') ->
	    ret [Definition (DeclSource cs) ts' ds']


    bindToAbstract (NiceAbstract r ds) ret =
	bindToAbstract ds $ \ds' ->
	    ret [A.Abstract (DeclRange r) ds']

    bindToAbstract (NiceModule r a (QName x) tel ds) ret =
	do  (tel',ds',ns) <-
		insideModule (QName x) $
		bindToAbstract (tel,ds) $ \ (tel',ds') ->
		    do	ns <- currentNameSpace
			return (tel',ds',ns)
	    let m = ModuleInfo { moduleArity	= length tel
			       , moduleAccess	= a
			       , moduleContents = ns
			       }
	    defineModule x m $
		ret [A.Module (mkRangedDefInfo defaultFixity a r)
			      (QName x) tel' ds']

    -- Top-level modules are translated with toAbstract.
    bindToAbstract (NiceModule _ _ _ _ _) _ = __IMPOSSIBLE__

    bindToAbstract (NiceModuleMacro r a x tel e is) ret =
	case appView e of
	    AppView (Ident m) args  ->
		bindToAbstract tel $ \tel' ->
		    do  args' <- toAbstract args
			implicitModule x a (length tel) m is $
			    ret [ ModuleDef (mkRangedDefInfo defaultFixity a r)
					    x tel' m args'
				]
		    
	    _	-> notAModuleExpr e

    bindToAbstract (NiceOpen r x is) ret =
	openModule x is $ ret [A.Open $ DeclSource [C.Open r x is]]

    bindToAbstract (NiceImport r x as is) ret =
	do  iface <- getModuleInterface x
	    importModule name iface is $ ret [A.Import (DeclRange r) x]
	where
	    name = maybe x QName as

newtype Constr a = Constr a

instance ToAbstract (Constr CD.NiceDeclaration) A.Declaration where
    toAbstract (Constr (CD.Axiom r f a x t)) =
	do  t' <- toAbstractCtx TopCtx t
	    return (A.Axiom (mkRangedDefInfo f a r) x t')

    toAbstract _ = __IMPOSSIBLE__    -- a constructor is always an axiom

instance BindToAbstract (Constr A.Declaration) () where
    bindToAbstract (Constr (A.Axiom info x t)) ret =
	defineName (defAccess info) ConName (defFixity info) x
	    $ ret ()

    bindToAbstract _ _ = __IMPOSSIBLE__    -- a constructor is always an axiom

instance ToAbstract CD.Clause A.Clause where
    toAbstract (CD.Clause lhs rhs wh) =
	bindToAbstract lhs $ \lhs' ->	-- the order matters here!
	bindToAbstract wh  $ \wh'  ->
	    do	rhs' <- toAbstractCtx TopCtx rhs
		return $ A.Clause lhs' rhs' wh'

instance BindToAbstract C.LHS A.LHS where
    bindToAbstract lhs@(C.LHS _ _ x as) ret =
	bindToAbstract as $ \as' ->
	ret (A.LHS (LHSSource lhs) x as')

instance BindToAbstract c a => BindToAbstract (Arg c) (Arg a) where
    bindToAbstract (Arg h e) ret = bindToAbstract e $ ret . Arg h

instance ToAbstract c a => ToAbstract (Arg c) (Arg a) where
    toAbstract (Arg h e) = Arg h <$> toAbstractCtx (hiddenArgumentCtx h) e

instance BindToAbstract C.Pattern A.Pattern where
    bindToAbstract p@(C.IdentP x) ret =
	do  rx <- resolvePatternNameM x	-- only returns VarName, ConName or UnknownName
	    case rx of
		VarName y   -> bindVariable y $ ret (VarP y)
		DefName d | kindOfName d == ConName
			    -> ret $ ConP (PatSource (getRange p) $ const p)
					  (theName d) []
		UnknownName -> notInScope x
		_	    -> __IMPOSSIBLE__
    bindToAbstract p0@(AppP h p q) ret =
	bindToAbstract (p,q) $ \(p',q') ->
	case p' of
	    ConP _ x as -> ret $ ConP info x (as ++ [Arg h q'])
	    _		-> higherOrderPattern p0 p
	where
	    r = getRange p0
	    info = PatSource r $ \pr -> if appBrackets pr then ParenP r p0 else p0

    bindToAbstract p0@(InfixAppP _ _ _) ret =
	do  f <- getFixityFunction
	    case rotateInfixAppP f p0 of
		InfixAppP p op q ->
		    bindToAbstract (C.IdentP op) $ \pop ->
		    case pop of
			ConP _ op' []   ->
			    bindToAbstract (p,q) $ \ (p',q') ->
			    ret $ ConP info op'
				$ map (Arg NotHidden) [p',q']
			_ -> higherOrderPattern p0 (C.IdentP op)
		_ -> __IMPOSSIBLE__ -- rotating an infix app produces an infix app
	where
	    r = getRange p0
	    info = PatSource r $ \pr -> if piBrackets pr
					then ParenP r p0
					else p0
		-- TODO: get the real fixity of the operator and use infixBrackets

    bindToAbstract p@(C.WildP r) ret  = ret $ A.WildP (PatSource r $ const p)
    bindToAbstract (C.ParenP _ p) ret = bindToAbstract p ret


{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module L0C.EnablingOpts.CopyCtPropFold
  ( copyCtProp
  , copyCtPropOneLambda
  )
  where

import Control.Applicative
import Control.Monad.Reader
import Control.Monad.Writer

import Data.List

import Data.Loc

import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet      as HS

import L0C.InternalRep
import L0C.EnablingOpts.EnablingOptErrors
import L0C.EnablingOpts.Simplification
import qualified L0C.Interpreter as Interp
import L0C.Tools

-----------------------------------------------------------------
-----------------------------------------------------------------
---- Copy and Constant Propagation + Constant Folding        ----
-----------------------------------------------------------------
-----------------------------------------------------------------

-----------------------------------------------
-- The data to be stored in vtable           --
--   the third param (Bool) indicates if the --
--   binding is to be removed from program   --
-----------------------------------------------

data CtOrId  = Value Value
             -- ^ value for constant propagation

             | VarId VName Type
             -- ^ Variable id for copy propagation

             | SymArr Exp
             -- ^ Various other opportunities for copy propagation,
             -- for the moment: (i) an indexed variable, (ii) a iota
             -- array, (iii) a replicated array, (iv) a TupLit, and
             -- (v) an ArrayLit.  I leave this one open, i.e., Exp, as
             -- I do not know exactly what we need here To Cosmin:
             -- Clean it up in the end, i.e., get rid of Exp.
               deriving (Show)

data CPropEnv = CopyPropEnv {
    envVtable  :: HM.HashMap VName CtOrId,
    program    :: Prog
  }


data CPropRes = CPropRes {
    resSuccess :: Bool
  -- ^ Whether we have changed something.
  }


instance Monoid CPropRes where
  CPropRes c1 `mappend` CPropRes c2 =
    CPropRes (c1 || c2)
  mempty = CPropRes False

newtype CPropM a = CPropM (WriterT CPropRes (ReaderT CPropEnv (Either EnablingOptError)) a)
    deriving (MonadWriter CPropRes,
              MonadReader CPropEnv,
              Monad, Applicative, Functor)

-- | We changed part of the AST, and this is the result.  For
-- convenience, use this instead of 'return'.
changed :: a -> CPropM a
changed x = do
  tell $ CPropRes True
  return x

-- | The identifier was consumed, and should not be used within the
-- body, so mark it and any aliases as nonremovable (with
-- 'nonRemovable') and delete any expressions using it or an alias
-- from the symbol table.
consuming :: Ident -> CPropM a -> CPropM a
consuming idd m = do
  (vtable, _) <- spartition ok <$> asks envVtable
  local (\e -> e { envVtable = vtable }) m
  where als = identName idd `HS.insert` aliases (identType idd)
        spartition f s = let s' = HM.filter f s
                         in (s', s `HM.difference` s')
        ok (Value {})  = True
        ok (VarId k _) = not $ k `HS.member` als
        ok (SymArr e)  = HS.null $ als `HS.intersection` freeNamesInExp e

-- | The enabling optimizations run in this monad.  Note that it has no mutable
-- state, but merely keeps track of current bindings in a 'TypeEnv'.
-- The 'Either' monad is used for error handling.
runCPropM :: CPropM a -> CPropEnv -> Either EnablingOptError (a, CPropRes)
runCPropM  (CPropM a) = runReaderT (runWriterT a)

badCPropM :: EnablingOptError -> CPropM a
badCPropM = CPropM . lift . lift . Left


-- | Bind a name as a common (non-merge) variable.
bindVar :: CPropEnv -> (VName, CtOrId) -> CPropEnv
bindVar env (name,val) =
  env { envVtable = HM.insert name val $ envVtable env }

bindVars :: CPropEnv -> [(VName, CtOrId)] -> CPropEnv
bindVars = foldl bindVar

binding :: [(VName, CtOrId)] -> CPropM a -> CPropM a
binding bnds = local (`bindVars` bnds)

varLookup :: CPropM VarLookup
varLookup = do
  env <- ask
  return $ \k -> asExp <$> HM.lookup k (envVtable env)
  where asExp (SymArr e)      = e
        asExp (VarId vname t) = SubExp $ Var $ Ident vname t noLoc
        asExp (Value val)     = SubExp (Constant val noLoc)

-- | Applies Copy/Constant Propagation and Folding to an Entire Program.
copyCtProp :: Prog -> Either EnablingOptError (Bool, Prog)
copyCtProp prog = do
  let env = CopyPropEnv { envVtable = HM.empty, program = prog }
  -- res   <- runCPropM (mapM copyCtPropFun prog) env
  -- let (bs, rs) = unzip res
  (rs, res) <- runCPropM (mapM copyCtPropFun $ progFunctions prog) env
  return (resSuccess res, Prog rs)

copyCtPropFun :: FunDec -> CPropM FunDec
copyCtPropFun (fname, rettype, args, body, pos) = do
  body' <- copyCtPropBody body
  return (fname, rettype, args, body', pos)

-----------------------------------------------------------------
---- Run on Lambda Only!
-----------------------------------------------------------------

copyCtPropOneLambda :: Prog -> Lambda -> Either EnablingOptError Lambda
copyCtPropOneLambda prog lam = do
  let env = CopyPropEnv { envVtable = HM.empty, program = prog }
  (res, _) <- runCPropM (copyCtPropLambda lam) env
  return res

--------------------------------------------------------------------
--------------------------------------------------------------------
---- Main functions: Copy/Ct propagation and folding for exps   ----
--------------------------------------------------------------------
--------------------------------------------------------------------

copyCtPropBody :: Body -> CPropM Body

copyCtPropBody (LetWith cs dest src inds el body pos) = do
  src' <- copyCtPropIdent src
  consuming src' $ do
    cs'    <- copyCtPropCerts cs
    el'    <- copyCtPropSubExp el
    inds'  <- mapM copyCtPropSubExp inds
    body'  <- copyCtPropBody body
    dest'  <- copyCtPropBnd dest
    return $ LetWith cs' dest' src' inds' el' body' pos

copyCtPropBody (LetPat pat e body loc) = do
  pat' <- copyCtPropPat pat
  let continue e' = do
        let bnds = getPropBnds pat' e'
        body' <- binding bnds $ copyCtPropBody body
        return $ LetPat pat' e' body' loc
      continue' _ es = continue $ TupLit es loc
  e' <- copyCtPropExp e
  look <- varLookup
  case e' of
    If e1 tb fb _ _
      | isCt1 e1 -> mapResultM continue' tb
      | isCt0 e1 -> mapResultM continue' fb
    _
      | Just res  <- simplifyBinding look (LetBind pat e') ->
        copyCtPropBody $ insertBindings' body res
    _ -> continue e'

copyCtPropBody (DoLoop merge idd n loopbody letbody loc) = do
  let (mergepat, mergeexp) = unzip merge
  mergepat' <- copyCtPropPat mergepat
  mergeexp' <- mapM copyCtPropSubExp mergeexp
  n'        <- copyCtPropSubExp n
  loopbody' <- copyCtPropBody loopbody
  look      <- varLookup
  let merge' = zip mergepat' mergeexp'
  case simplifyBinding look (LoopBind merge' idd n' loopbody') of
    Nothing -> do letbody' <- copyCtPropBody letbody
                  return $ DoLoop merge' idd n' loopbody' letbody' loc
    Just bnds -> copyCtPropBody $ insertBindings' letbody bnds

copyCtPropBody (Result cs es loc) =
  Result <$> copyCtPropCerts cs <*> mapM copyCtPropSubExp es <*> pure loc

copyCtPropSubExp :: SubExp -> CPropM SubExp
copyCtPropSubExp (Var ident@(Ident vnm _ pos)) = do
  bnd <- asks $ HM.lookup vnm . envVtable
  case bnd of
    Just (Value v)
      | isBasicTypeVal v  -> changed $ Constant v pos
    Just (VarId  id' tp1) -> changed $ Var (Ident id' tp1 pos) -- or tp
    Just (SymArr (SubExp se)) -> changed se
    _                         -> Var <$> copyCtPropBnd ident
copyCtPropSubExp (Constant v loc) = return $ Constant v loc

copyCtPropExp :: Exp -> CPropM Exp

-- The simplification engine cannot handle Apply, because it requires
-- access to the full program.
copyCtPropExp (Apply fname args tp pos) = do
    args' <- mapM (copyCtPropSubExp . fst) args
    (all_are_vals, vals) <- allArgsAreValues args'
    if all_are_vals
    then do prg <- asks program
            let vv = Interp.runFunNoTrace fname vals  prg
            case vv of
              Right [v] -> changed $ SubExp $ Constant v pos
              Right vs  -> changed $ TupLit (map (`Constant` pos) vs) pos
              Left e    -> badCPropM $ EnablingOptError
                           pos (" Interpreting fun " ++ nameToString fname ++
                                " yields error:\n" ++ show e)
    else return $ Apply fname (zip args' $ map snd args) tp pos

    where
        allArgsAreValues :: [SubExp] -> CPropM (Bool, [Value])
        allArgsAreValues []     = return (True, [])
        allArgsAreValues (a:as) =
            case a of
                Constant v _ -> do (res, vals) <- allArgsAreValues as
                                   if res then return (True,  v:vals)
                                          else return (False, []    )
                Var idd   -> do vv <- asks $ HM.lookup (identName idd) . envVtable
                                case vv of
                                  Just (Value v) -> do
                                    (res, vals) <- allArgsAreValues as
                                    if res then return (True,  v:vals)
                                           else return (False, []    )
                                  _ -> return (False, [])

copyCtPropExp e = mapExpM mapper e
  where mapper = Mapper {
                   mapOnExp = copyCtPropExp
                 , mapOnBody = copyCtPropBody
                 , mapOnSubExp = copyCtPropSubExp
                 , mapOnLambda = copyCtPropLambda
                 , mapOnIdent = copyCtPropIdent
                 , mapOnCertificates = copyCtPropCerts
                 , mapOnType = copyCtPropType
                 , mapOnValue = return
                 }

copyCtPropPat :: [IdentBase als Shape] -> CPropM [IdentBase als Shape]
copyCtPropPat = mapM copyCtPropBnd

copyCtPropBnd :: IdentBase als Shape -> CPropM (IdentBase als Shape)
copyCtPropBnd (Ident vnm t loc) = do
  t' <- copyCtPropType t
  return $ Ident vnm t' loc

copyCtPropType :: TypeBase als Shape -> CPropM (TypeBase als Shape)
copyCtPropType t = do
  dims <- mapM copyCtPropSubExp $ arrayDims t
  return $ t `setArrayDims` dims

copyCtPropIdent :: Ident -> CPropM Ident
copyCtPropIdent ident@(Ident vnm _ loc) = do
    bnd <- asks $ HM.lookup vnm . envVtable
    case bnd of
      Just (VarId  id' tp1) -> changed $ Ident id' tp1 loc
      Nothing               -> copyCtPropBnd ident
      _                     -> copyCtPropBnd ident

copyCtPropCerts :: Certificates -> CPropM Certificates
copyCtPropCerts = liftM (nub . concat) . mapM check
  where check idd = do
          vv <- asks $ HM.lookup (identName idd) . envVtable
          case vv of
            Just (Value (BasicVal Checked)) -> changed []
            Just (VarId  id' tp1)           -> changed [Ident id' tp1 loc]
            _ -> return [idd]
          where loc = srclocOf idd

copyCtPropLambda :: Lambda -> CPropM Lambda
copyCtPropLambda (Lambda params body rettype loc) = do
  params' <- copyCtPropPat params
  body' <- copyCtPropBody body
  rettype' <- mapM copyCtPropType rettype
  return $ Lambda params' body' rettype' loc

----------------------------------------------------
---- Helpers for Constant Folding                ---
----------------------------------------------------

isCt1 :: SubExp -> Bool
isCt1 (Constant (BasicVal (IntVal x))  _) = x == 1
isCt1 (Constant (BasicVal (RealVal x)) _) = x == 1
isCt1 (Constant (BasicVal (LogVal x))  _) = x
isCt1 _                                   = False

isCt0 :: SubExp -> Bool
isCt0 (Constant (BasicVal (IntVal x))  _) = x == 0
isCt0 (Constant (BasicVal (RealVal x)) _) = x == 0
isCt0 (Constant (BasicVal (LogVal x))  _) = not x
isCt0 _                                   = False

----------------------------------------------------
---- Helpers for Constant/Copy Propagation       ---
----------------------------------------------------

isBasicTypeVal :: Value -> Bool
isBasicTypeVal = basicType . valueType

getPropBnds :: [Ident] -> Exp -> [(VName, CtOrId)]
getPropBnds [ident@(Ident var _ _)] e =
  case e of
    SubExp (Constant v _) -> [(var, Value v)]
    SubExp (Var v)        -> [(var, VarId (identName v) (identType v))]
    Index   {}            -> [(var, SymArr e)]
    TupLit  [e'] _        -> getPropBnds [ident] $ SubExp e'
    Rearrange   {}        -> [(var, SymArr e)]
    Rotate      {}        -> [(var, SymArr e)]
    Reshape   {}          -> [(var, SymArr e)]
    Conjoin {}            -> [(var, SymArr e)]

    Iota {}               -> [(var, SymArr e)]
    Replicate {}          -> [(var, SymArr e)]
    ArrayLit  {}          -> [(var, SymArr e)]
    _                     -> []
getPropBnds ids (TupLit ts _)
  | length ids == length ts =
    concatMap (\(x,y)-> getPropBnds [x] (SubExp y)) $ zip ids ts
getPropBnds _ _ = []

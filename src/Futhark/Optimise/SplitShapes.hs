-- | For every function with an existential return shape, try to see
-- if we can extract an efficient shape slice.  If so, replace every
-- call of the original function with a function to the shape and
-- value slices.
module Futhark.Optimise.SplitShapes
       (splitShapes)
where

import Control.Applicative
import Control.Monad.State
import Control.Monad.Writer

import qualified Data.HashMap.Lazy as HM
import Data.Maybe

import Futhark.Representation.Basic
import Futhark.Tools
import Futhark.MonadFreshNames
import Futhark.Renamer
import Futhark.Substitute
import Futhark.Optimise.Simplifier
import Futhark.Optimise.DeadVarElim

-- | Perform the transformation on a program.
splitShapes :: Prog -> Prog
splitShapes prog =
  Prog { progFunctions = evalState m (newNameSourceForProg prog) }
  where m = do let origfuns = progFunctions prog
               (substs, newfuns) <-
                 unzip <$> map extract <$>
                 makeFunSubsts origfuns
               mapM (substCalls substs) $ origfuns ++ concat newfuns
        extract (fname, (shapefun, valfun)) =
          ((fname, (funDecName shapefun, funDecRetType shapefun,
                    funDecName valfun, funDecRetType valfun)),
           [shapefun, valfun])

makeFunSubsts :: MonadFreshNames m =>
                 [FunDec] -> m [(Name, (FunDec, FunDec))]
makeFunSubsts fundecs =
  cheapSubsts <$>
  zip (map funDecName fundecs) <$>
  mapM (simplifyShapeFun' <=< functionSlices) fundecs
  where simplifyShapeFun' (shapefun, valfun) = do
          shapefun' <- simplifyShapeFun shapefun
          return (shapefun', valfun)

-- | Returns shape slice and value slice.  The shape slice duplicates
-- the entire value slice - you should try to simplify it, and see if
-- it's "cheap", in some sense.
functionSlices :: MonadFreshNames m => FunDec -> m (FunDec, FunDec)
functionSlices (fname, rettype, params, body@(Body bodybnds bodyres), loc) = do
  -- The shape function should not consume its arguments - if it wants
  -- to do in-place stuff, it needs to copy them first.  In most
  -- cases, these copies will be removed by the simplifier.
  (shapeParams, cpybnds) <- nonuniqueParams params

  -- Give names to the existentially quantified sizes of the return
  -- type.  These will be passed as parameters to the value function.
  (staticRettype, shapeidents) <-
    runWriterT $ map (`setAliases` ()) <$> instantiateShapes instantiate rettype

  valueBody <- substituteExtResultShapes staticRettype body

  let valueRettype = staticShapes staticRettype
      valueParams = map toParam shapeidents ++ params
      shapeBody = Body (cpybnds <> bodybnds) bodyres { resultSubExps = shapes }
      fShape = (shapeFname, shapeRettype, shapeParams, shapeBody, loc)
      fValue = (valueFname, valueRettype, valueParams, valueBody, loc)
  return (fShape, fValue)
  where shapes = subExpShapeContext rettype $ resultSubExps bodyres
        shapeRettype = staticShapes $ map ((`setAliases` ()) . subExpType) shapes
        shapeFname = fname <> nameFromString "_shape"
        valueFname = fname <> nameFromString "_value"

        instantiate = do v <- lift $ newIdent "precomp_shape" (Basic Int) loc
                         tell [v]
                         return $ Var v

substituteExtResultShapes :: MonadFreshNames m => [ConstType] -> Body -> m Body
substituteExtResultShapes rettype (Body bnds res) = do
  bnds' <- mapM substInBnd bnds
  let res' = res { resultSubExps = map (substituteNames subst) $
                                   resultSubExps res
                 }
  return $ Body bnds' res'
  where typesShapes = concatMap (shapeDims . arrayShape)
        compshapes =
          typesShapes $ map subExpType $ resultSubExps res
        subst =
          HM.fromList $ mapMaybe isSubst $ zip compshapes (typesShapes rettype)
        isSubst (Var v1, Var v2) = Just (identName v1, identName v2)
        isSubst _                = Nothing

        substInBnd (Let pat () e) =
          Let <$> mapM substInBnd' pat <*> pure () <*> pure (substituteNames subst e)
        substInBnd' v
          | identName v `HM.member` subst = newIdent' (<>"unused") v
          | otherwise                     = return v

simplifyShapeFun :: MonadFreshNames m => FunDec -> m FunDec
simplifyShapeFun shapef = return . deadCodeElimFun =<< simplifyFun =<<
                          return . deadCodeElimFun =<< simplifyFun =<<
                          return . deadCodeElimFun =<< simplifyFun =<<
                          return . deadCodeElimFun =<< simplifyFun =<<
                          return . deadCodeElimFun =<< simplifyFun =<<
                          return . deadCodeElimFun =<< simplifyFun =<<
                          renameFun shapef

cheapFun :: FunDec -> Bool
cheapFun  = cheapBody . funDecBody
  where cheapBody (Body bnds _) = all cheapBinding bnds
        cheapBinding (Let _ _ e) = cheap e
        cheap (DoLoop {}) = False
        cheap (Map {}) = False
        cheap (Apply {}) = False
        cheap (Reduce {}) = False
        cheap (Scan {}) = False
        cheap (Redomap {}) = False
        cheap (If _ tbranch fbranch _ _) = cheapBody tbranch && cheapBody fbranch
        cheap _ = True

cheapSubsts :: [(Name, (FunDec, FunDec))] -> [(Name, (FunDec, FunDec))]
cheapSubsts = filter (cheapFun . fst . snd)
              -- Probably too simple.  We might want to inline first.

substCalls :: MonadFreshNames m => [(Name, (Name, RetType, Name, RetType))] -> FunDec -> m FunDec
substCalls subst (origFname,origRettype,params,fbody,origloc) = do
  fbody' <- treatBody fbody
  return (origFname, origRettype, params, fbody', origloc)
  where treatBody (Body bnds res) = do
          bnds' <- mapM treatBinding bnds
          return $ Body (concat bnds') res
        treatLambda lam = do
          body <- treatBody $ lambdaBody lam
          return $ lam { lambdaBody = body }

        treatBinding (Let pat () (Apply fname args _ loc))
          | Just (shapefun,shapetype,valfun,valtype) <- lookup fname subst =
            liftM snd . runBinder'' $ do
              let (vs,vals) = splitAt (length shapetype) pat
                  shapeargs = [ (arg, Observe) | (arg,_) <- args ]
                  shapetype' = returnType shapetype (repeat Observe) $
                               map (subExpType . fst) shapeargs
                  valtype' = returnType valtype (map snd args) $
                             map (subExpType . fst) args
              letBind vs $ Apply shapefun args shapetype' loc
              letBind vals $ Apply valfun ([(Var v,Observe) | v <- vs]++args) valtype' loc

        treatBinding (Let pat () e) = do
          e' <- mapExpM mapper e
          return [Let pat () e']
          where mapper = identityMapper { mapOnBody = treatBody
                                        , mapOnLambda = treatLambda
                                        }

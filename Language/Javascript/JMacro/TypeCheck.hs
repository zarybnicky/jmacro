{-# LANGUAGE GeneralizedNewtypeDeriving, FlexibleInstances, PatternGuards #-}

module Language.Javascript.JMacro.TypeCheck where

import Language.Javascript.JMacro.Base
import Language.Javascript.JMacro.Types
import Language.Javascript.JMacro.QQ

import Control.Applicative
import Control.Monad
import Control.Monad.State
import Control.Monad.Writer
import Control.Monad.Error
import Data.Map (Map)
import Data.Maybe(catMaybes, fromMaybe)
import Data.List(intercalate, nub)
import qualified Data.Traversable as T
import qualified Data.Map as M
import Data.Set(Set)
import qualified Data.Set as S

import Text.PrettyPrint.HughesPJ

import Debug.Trace

-- Utility

partitionOut :: (a -> Maybe b) -> [a] -> ([b],[a])
partitionOut f xs' = foldr go ([],[]) xs'
    where go x ~(bs,as)
             | Just b <- f x = (b:bs,as)
             | otherwise = (bs,x:as)

zipWithOrChange :: (a -> a -> b) -> (a -> b) -> [a] -> [a] -> [b]
zipWithOrChange f g xss yss = go xss yss
    where go (x:xs) (y:ys) = f x y : go xs ys
          go xs@(_:_) _ = map g xs
          go _ ys = map g ys

zipWithOrIdM :: Monad m => (a -> a -> m a) -> [a] -> [a] -> m [a]
zipWithOrIdM f xs ys = sequence $ zipWithOrChange f return xs ys

unionWithM :: (Monad m, Ord key) => (val -> val -> m val) -> Map key val -> Map key val -> m (Map key val)
unionWithM f m1 m2 = T.sequence $ M.unionWith (\xm ym -> join $ liftM2 f xm ym) (M.map return m1) (M.map return m2)

intersectionWithM :: (Monad m, Ord key) => (val -> val -> m b) -> Map key val -> Map key val -> m (Map key b)
intersectionWithM f m1 m2 = T.sequence $ M.intersectionWith f m1 m2

-- Basic Types and TMonad
data StoreVal = SVType JType
              | SVConstrained (Set Constraint)
              -- | SVFreshType Int
                deriving Show

data TCState = TCS {tc_env :: [Map Ident JType],
                    tc_vars :: Map Int StoreVal,
                    tc_stack :: [Set Int],
                    tc_frozen :: Set Int,
                    tc_varCt :: Int} deriving Show

tcStateEmpty = TCS [M.empty] M.empty [S.empty] S.empty 0

newtype TMonad a = TMonad (ErrorT String (State TCState) a) deriving (Functor, Monad, MonadState TCState, MonadError String, Applicative)

instance Applicative (ErrorT String (State TCState)) where
    pure = return
    (<*>) = ap

class JTypeCheck a where
    typecheck :: a -> TMonad JType

evalTMonad (TMonad x) = evalState (runErrorT x) tcStateEmpty

runTMonad (TMonad x) = runState (runErrorT x) tcStateEmpty

--assums x is resolved
--TODO pull names from forall...
freeVarsWithNames :: JType -> TMonad (Map Int String)
freeVarsWithNames x =
  fmap (either id int2Name) . (\(a,_,_) -> a) <$>
       execStateT (go x) (M.empty, S.empty, 0)
    where
      go :: JType -> StateT (Map Int (Either String Int), Set String, Int) TMonad ()
      go (JTFree (mbName, ref)) = do
        (m,ns,ct) <- get
        let mkUnique n i
                | n' `S.member` ns = mkUnique n (i + 1)
                | otherwise = n'
               where n' | i == 0 = n
                        | otherwise = n ++ show i
            putName n =
                let n' = mkUnique n 0
                in put (M.insert ref (Left n') m, S.insert n' ns, ct)
        case M.lookup ref m of
          Just (Left _) -> return ()
          Just (Right _) -> case mbName of
                              Just name -> putName name
                              Nothing -> return ()
          Nothing -> do case mbName of
                          Just name -> putName name
                          Nothing -> put (M.insert ref (Right ct) m, ns, ct + 1)
                        mapM_ (go . fromC) =<< lift (lookupConstraintsList (mbName, ref))
      go v = composOpM_ go v

      fromC (Sub t) = t
      fromC (Super t) = t

      int2Name i | q == 0 = [letter]
                 | otherwise = letter : show q
          where (q,r) = divMod i 26
                letter = toEnum (fromEnum 'a' + r)

prettyType x = do
  xt <- resolveType x
  names <- freeVarsWithNames xt
  let replaceNames (JTFree ref) = JTFree $ fixRef ref
      replaceNames (JTForall refs t) = JTForall (map fixRef refs) $ replaceNames t
      replaceNames v = composOp replaceNames v

      fixRef (_,ref) = (M.lookup ref names, ref)

      prettyConstraints ref = map go <$> lookupConstraintsList (Nothing, ref)
          where
            myName = case M.lookup ref names of
                       Just n -> n
                       Nothing -> "t_"++show ref
            go (Sub t) = myName ++ " <: " ++ (show $ jsToDoc $ replaceNames t)
            go (Super t) = (show $ jsToDoc $ replaceNames t) ++ " <: " ++ myName

  constraintStrings <- nub . concat <$> mapM prettyConstraints (M.keys names)

  let constraintStr
          | null constraintStrings = ""
          | otherwise = "(" ++ intercalate ", " constraintStrings ++ ") => "

  return $ constraintStr ++ (show . jsToDoc $ replaceNames xt)

tyErr0 :: String -> TMonad a
tyErr0 x = throwError x

tyErr1 :: String -> JType -> TMonad b
tyErr1 s t = do
  st <- prettyType t
  throwError $ s ++ ": " ++ st

tyErr2 :: String -> JType -> JType -> TMonad a
tyErr2 s t t' = do
  st <- prettyType t
  st' <- prettyType t'
  throwError $ s ++ ". Expected: " ++ st ++ ", Inferred: " ++ st'

prettyEnv :: TMonad [Map Ident String]
prettyEnv = mapM (T.mapM prettyType) . tc_env =<< get

runTypecheckFull x = runTMonad $ do
                       r <- prettyType =<< typecheckMain x
                       e <- prettyEnv
                       return (r,e)

runTypecheck x = evalTMonad $ prettyType =<< typecheckMain x

evalTypecheck x = evalTMonad $ do
                    _ <- typecheckMain x
                    e <- prettyEnv
                    return e

typecheckMain x = do
  r <- typecheck x
  setFrozen . S.unions . tc_stack =<< get
  tryCloseFrozenVars
  return r

-- Manipulating VarRefs and Constraints

addToStack v (s:ss) = S.insert v s : ss
addToStack _ _ = error "addToStack: no sets" --[S.singleton v]

newVarRef :: TMonad VarRef
newVarRef = do
  v <- tc_varCt <$> get
  modify (\s -> s {tc_varCt = v + 1,
                   tc_stack = addToStack v (tc_stack s)})
  return $ (Nothing, v)

newTyVar :: TMonad JType
newTyVar = JTFree <$> newVarRef

{-
freshType :: TMonad JType
freshType = do
  vr@(_,ref) <- newVarRef
  modify (\s -> s {tc_vars = M.insert ref (SVFreshType ref) (tc_vars s)})
  return $ JTFree vr
-}

mapConstraint :: (Monad m, Functor m) => (JType -> m JType) -> Constraint -> m Constraint
mapConstraint f (Sub t) = Sub <$> f t
mapConstraint f (Super t) = Super <$> f t

--add mutation
lookupConstraintsList :: VarRef -> TMonad [Constraint]
lookupConstraintsList vr@(_,ref) = do
  vars <- tc_vars <$> get
  case M.lookup ref vars of
    (Just (SVConstrained cs)) -> mapM (mapConstraint resolveType) (S.toList cs)
    (Just (SVType t)) -> tyErr1 "lookupConstraints on instantiated type" t
--    (Just (SVFreshType t)) -> tyErr1 "lookupConstraints on qualified (fresh) type" (JTFree vr)
    Nothing -> return []

instantiateVarRef :: VarRef -> JType -> TMonad ()
instantiateVarRef vr@(_,ref) t = do
    cs <- lookupConstraintsList vr
    modify (\s -> s {tc_vars = M.insert ref (SVType t) (tc_vars s)})
    checkConstraints t cs

checkConstraints :: JType -> [Constraint] -> TMonad ()
checkConstraints t cs = mapM_ go cs
    where go (Sub t2) = t <: t2
          go (Super t2) = t2 <: t


--TODO: collect foralls and do contra or covariant some upper or some lower and regeneralize
addConstraint :: VarRef -> Constraint -> TMonad ()
addConstraint vr@(_,ref) c = case c of
       Sub t -> case t of
                  JTFree _ -> addC c

                  -- x <: \/ a. t, x <: \/ b. t2 --->
                  -- x <: \/ a b. y, y <: [t], y <: [t2]

                  --TODO: test
                  JTForall vars t -> do
                         let mergeForall (vs1,b1) (vs2,b2) = do
                               rt <- newTyVar
                               (_, frame) <- withLocalScope $ do
                                     t1 <- instantiateScheme vs1 b1
                                     t2 <- instantiateScheme vs2 b2
                                     rt <: t1
                                     rt <: t2
                               addRefsToStack $ frame
                               -- TODO we can set some frozen, but how...
                               return (frame2VarRefs frame, rt)

                         (foralls,restCs) <- findForallSubs <$> lookupConstraintsList vr
                         (vars',t') <- foldM mergeForall (vars,t) foralls
                         t'' <- resolveType $ JTForall vars' t'
                         putCs (S.fromList $ Sub t'' : restCs)

                  JTForall vars t -> addC c --we can make this smarter later

                  JTFunc args res -> do
                         args' <- mapM (const newTyVar) args
                         res'  <- newTyVar
                         zipWithM_ (<:) args args' --contravariance
                         res' <: res
                         instantiateVarRef vr $ JTFunc args' res'

                  JTRecord m -> do
                         (ms,restCs) <- findRecordSubs <$> lookupConstraintsList vr
                         t' <- JTRecord <$> foldM (unionWithM (\x y -> someLowerBound [x,y])) m ms
                         putCs (S.fromList $ Sub t' : restCs)

                  JTList t' -> do
                         vr' <- newVarRef
                         addConstraint vr' (Sub t')
                         instantiateVarRef vr (JTList (JTFree vr'))

                  JTMap t' -> do
                         vr' <- newVarRef
                         addConstraint vr' (Sub t')
                         instantiateVarRef vr (JTMap (JTFree vr'))

                  _ -> do
                         instantiateVarRef vr t

       Super t -> case t of
                  JTFree _ -> addC c

                  --TODO: test more
                  JTForall vars t -> do
                         let mergeForall (vs1,b1) (vs2,b2) = do
                               rt <- newTyVar
                               (_, frame) <- withLocalScope $ do
                                     t1 <- instantiateScheme vs1 b1
                                     t2 <- instantiateScheme vs2 b2
                                     t1 <: rt
                                     t2 <: rt
                               addRefsToStack $ frame
                               -- TODO we can set some frozen, but how...
                               return (frame2VarRefs frame, rt)

                         (foralls,restCs) <- findForallSups <$> lookupConstraintsList vr
                         (vars',t') <- foldM mergeForall (vars,t) foralls
                         t'' <- resolveType $ JTForall vars' t'
                         putCs (S.fromList $ Super t'' : restCs)


                  JTForall vars t -> addC c --we can make this smarter later
                  JTFunc args res -> do
                         args' <- mapM (const newTyVar) args
                         res'  <- newTyVar
                         zipWithM_ (<:) args' args --contravariance
                         res <: res'
                         instantiateVarRef vr $ JTFunc args' res'

                  JTRecord m -> do
                         (ms,restCs) <- findRecordSups <$> lookupConstraintsList vr
                         t' <- JTRecord <$> foldM (intersectionWithM (\x y -> someUpperBound [x,y])) m ms
                         putCs (S.fromList $ Super t' : restCs)

                  JTList t' -> do
                         vr' <- newVarRef
                         addConstraint vr' (Super t')
                         instantiateVarRef vr (JTList (JTFree vr'))

                  JTMap t' -> do
                         vr' <- newVarRef
                         addConstraint vr' (Super t')
                         instantiateVarRef vr (JTMap (JTFree vr'))

                  _ -> do
                         instantiateVarRef vr t
    where
      putCs cs =
        modify (\s -> s {tc_vars = M.insert ref (SVConstrained cs) (tc_vars s)})

      addC constraint = do
        cs <- lookupConstraintsList vr
        modify (\s -> s {tc_vars = M.insert ref (SVConstrained (S.fromList $ constraint:cs)) (tc_vars s)})

      findRecordSubs cs = partitionOut go cs
          where go (Sub (JTRecord m)) = Just m
                go _ = Nothing

      findRecordSups cs = partitionOut go cs
          where go (Super (JTRecord m)) = Just m
                go _ = Nothing

      findForallSubs cs = partitionOut go cs
          where go (Sub (JTForall vars t)) = Just (vars,t)
                go _ = Nothing

      findForallSups cs = partitionOut go cs
          where go (Super (JTForall vars t)) = Just (vars,t)
                go _ = Nothing


tryCloseFrozenVars :: TMonad ()
tryCloseFrozenVars = return ()

-- Manipulating the environment
withLocalScope :: TMonad a -> TMonad (a, Set Int)
withLocalScope act = do
  modify (\s -> s {tc_env   = M.empty : tc_env s,
                   tc_stack = S.empty : tc_stack s})
  res <- act
  frame <- head . tc_stack <$> get
  modify (\s -> s {tc_env   = drop 1 $ tc_env s,
                   tc_stack = drop 1 $ tc_stack s})
  return (res, frame)

setFrozen :: Set Int -> TMonad ()
setFrozen x = modify (\s -> s {tc_frozen = tc_frozen s `S.union` x})

addRefsToStack x = modify (\s -> s {tc_stack = foldr addToStack (tc_stack s) (S.toList x) })

frame2VarRefs frame = (\x -> (Nothing,x)) <$> S.toList frame

addEnv :: Ident -> JType -> TMonad ()
addEnv ident typ = do
  envstack <- tc_env <$> get
  case envstack of
    (e:es) -> modify (\s -> s {tc_env = M.insert ident typ e : es}) -- we clobber/shadow var names
    _ -> throwError "empty env stack (this should never happen)"

newVarDecl :: Ident -> TMonad JType
newVarDecl ident = do
  v <- newTyVar
  addEnv ident v
  return v

--if a var in a forall isn't free, drop it.
resolveTypeGen :: ((JType -> TMonad JType) -> JType -> TMonad JType) -> JType -> TMonad JType
resolveTypeGen f typ = go typ
    where
      go :: JType -> TMonad JType
      go x@(JTFree (_, ref)) = do
        vars <- tc_vars <$> get
        case M.lookup ref vars of
          Just (SVType t) -> do
            res <- go t
            when (res /= t) $ modify (\s -> s {tc_vars = M.insert ref (SVType res) $ tc_vars s}) --mutation, shortcuts pointer chasing
            return res
          _ -> return x

      -- | Eliminates resolved vars from foralls, eliminates empty foralls.
      go (JTForall refs t) = do
        refs' <- catMaybes <$> mapM checkRef refs
        if null refs'
           then go t
           else JTForall refs' <$> go t
      go x = f go x

      checkRef x@(_, ref) = do
        vars <- tc_vars <$> get
        case M.lookup ref vars of
          Just (SVType t) -> return Nothing
          _ -> return $ Just x

resolveType = resolveTypeGen composOpM
resolveTypeShallow = resolveTypeGen (const return)

--TODO: generalize (i.e. implicit forall)
integrateLocalType :: JLocalType -> TMonad JType
integrateLocalType (env,typ) = do
  (r, frame) <- withLocalScope $ flip evalStateT M.empty $ do
                                 mapM_ integrateEnv env
                                 cloneType typ
  resolveType $ JTForall (frame2VarRefs frame) r
    where
      getRef (mbName, ref) = do
            m <- get
            case M.lookup ref m of
              Just newTy -> return newTy
              Nothing -> do
                newTy <- (\x -> JTFree (mbName, snd x)) <$> lift newVarRef
                put $ M.insert ref newTy m
                return newTy

      integrateEnv (vr,c) = do
        newTy <- getRef vr
        case c of
          (Sub t) -> lift . (newTy <:) =<< cloneType t
          (Super t) -> lift . (<: newTy) =<< cloneType t

      cloneType (JTFree vr) = getRef vr
      cloneType x = composOpM cloneType x

lookupEnv :: Ident -> TMonad JType
lookupEnv ident = resolveType =<< go . tc_env =<< get
    where go (e:es) = case M.lookup ident e of
                        Just t -> return t
                        Nothing -> go es
          go _ = tyErr0 $ "unable to resolve variable name: " ++ (show $ jsToDoc $ ident)


freeVars :: JType -> TMonad (Set Int)
freeVars t = execWriterT . go =<< resolveType t
    where go (JTFree (_, ref)) = tell (S.singleton ref)
          go x = composOpM_ go x

--only works on resolved types
instantiateScheme :: [VarRef] -> JType -> TMonad JType
instantiateScheme vrs t = evalStateT (go t) M.empty
    where
      schemeVars = S.fromList $ map snd vrs
      go :: JType -> StateT (Map Int JType) TMonad JType
      go (JTFree vr@(mbName, ref))
          | ref `S.member` schemeVars = do
                       m <- get
                       case M.lookup ref m of
                         Just newTy -> return newTy
                         Nothing -> do
                           newRef <- (\x -> (mbName, snd x)) <$> lift newVarRef
                           put $ M.insert ref (JTFree newRef) m
                           mapM_ (lift . addConstraint newRef <=< mapConstraint go) =<< lift (lookupConstraintsList vr)
                           return (JTFree newRef)
      go x = composOpM go x
{-
--only works on resolved types
instantiateSchemeWithFreshTypes :: [VarRef] -> JType -> ([JType],TMonad JType)
instantiateSchemeWithFreshTypes vrs t = do
  fts <- mapM (const newTyVar) vrs
  let m = M.fromList $ zip (map snd vrs) fts
      go x@(JTFree (_, ref)) = fromMaybe x $ M.lookup ref m
      go x = composOp go x
  return $ (fts, go t)
-}

-- Subtyping
(<:) :: JType -> JType -> TMonad ()
x <: y = do
     xt <- resolveTypeShallow x --shallow because subtyping can close
     yt <- resolveTypeShallow y
     if xt == yt
        then return ()
        else go xt yt
  where

    -- \/ a. t <: v --> [t] <: v
    --handle freevars that are FreshVars


    -- v <: \/ a. t --> v <: t[a:=x], x not in conclusion
{-
    go xt (JTForall vars t) = do
           t' <- instantiateScheme vars t
           go xt t'
-}
    go _ JTStat = return ()
    go xt@(JTFree ref) yt@(JTFree ref2) = addConstraint ref  (Sub yt) >>
                                          addConstraint ref2 (Super xt)
    go (JTFree ref) yt = addConstraint ref (Sub yt)
    go xt (JTFree ref) = addConstraint ref (Super xt)

{-
    --this is totally wrong
    go xt yt@(JTForall vars t) = do
           (t',fts) <- withLocalScope $ instantiateScheme vars t
           --freeze the vars. if vars are frozen, can't be constrained with *new* constraints, but existing constraints can be checked, new constraints added elsewhere
           go xt t'
           --then check that no fresh types appear in xt

    go (JTForall vars t) yt = do
           t' <- instantiateScheme vars t
           go t' yt
-}

    go xt@(JTFunc argsx retx) yt@(JTFunc argsy rety) = do
           -- TODO: zipWithM_ (<:) (appArgst ++ repeat JTStat) argst -- handle empty args cases
           when (length argsy < length argsx) $ tyErr2 "Couldn't subtype" xt yt
           zipWithM_ (<:) argsy argsx -- functions are contravariant in argument type
           retx <: rety -- functions are covariant in return type
    go (JTList xt) (JTList yt) = xt <: yt
    go (JTMap xt) (JTMap yt) = xt <: yt
    go (JTRecord xm) (JTRecord ym)
        | ym `M.isProperSubmapOf` xm = intersectionWithM (<:) xm ym >> return ()
    go xt yt = tyErr2 "Couldn't subtype" xt yt

someUpperBound :: [JType] -> TMonad JType
someUpperBound [] = return JTStat
-- someUpperBound [x] = return x
someUpperBound xs = trace (show xs) $ do
  res <- newTyVar
  mapM_ (<: res) xs
  return res

someLowerBound :: [JType] -> TMonad JType
someLowerBound [] = return JTImpossible
-- someLowerBound [x] = return x
someLowerBound xs = do
  res <- newTyVar
  mapM_ (res <:) xs
  return res

x =.= y = do
      x <: y
      y <: x
      return x

instance JTypeCheck JExpr where
    typecheck (ValExpr e) = typecheck e
    typecheck (SelExpr e (StrI i)) =
        do et <- typecheck e
           case et of
             (JTRecord m) -> case M.lookup i m of
                               Just res -> return res
                               Nothing -> tyErr1 ("Record contains no field named " ++ show i) et -- record extension would go here
             (JTFree r) -> do
                            res <- newTyVar
                            addConstraint r (Sub (JTRecord (M.singleton i res)))
                            return res
             _ -> tyErr1 "Cannot use record selector on this value" et
    typecheck (IdxExpr e e1) = undefined --this is tricky
    typecheck (InfixExpr s e e1)
        | s `elem` ["-","/","*"] = setFixed JTNum >> return JTNum
        | s == "+" = setFixed JTNum >> return JTNum -- `orElse` setFixed JTStr --TODO: Intersection types
        | s == "++" = setFixed JTString >> return JTString
        | s `elem` [">","<"] = setFixed JTNum >> return JTBool
        | s `elem` ["==","/="] = do
                            et <- typecheck e
                            e1t <- typecheck e1
                            et =.= e1t
                   -- equality means typechecking subtypes in both directions
        | s `elem` ["||","&&"] = setFixed JTBool >> return JTBool
        | otherwise = throwError $ "Unhandled operator: " ++ s
        where setFixed t = do
                  (<: t) =<< typecheck e
                  (<: t) =<< typecheck e1

    typecheck (PostExpr _ e) = case e of
                                 (SelExpr _ _) -> go
                                 (ValExpr (JVar _)) -> go
                                 (IdxExpr _ _) -> go
                                 _ -> tyErr1 "Value not compatible with postfix assignment" =<< typecheck e
        where go = ((<: JTNum) =<< typecheck e) >> return JTNum

    typecheck (IfExpr e e1 e2) = do
                            (<: JTBool) =<< typecheck e
                            t1 <- typecheck e1
                            t2 <- typecheck e2
                            someUpperBound [t1,t2] --t1 /\ t2

    typecheck (NewExpr e) = undefined --yipe

    --when we instantiate a scheme, all the elements of the head
    --that are not in the tail are henceforth unreachable and can be closed
    --but that's just an optimization
    typecheck (ApplExpr e appArgse) = do
                            et <- typecheck e
                            appArgst <- mapM typecheck appArgse
                            let go (JTForall vars t) = go =<< instantiateScheme vars t
                                go (JTFunc argst rett) = do
                                        zipWithM_ (<:) (appArgst ++ repeat JTStat) argst
                                        return rett
                                go (JTFree _) = do
                                        ret <- newTyVar
                                        et <: JTFunc appArgst ret
                                        return ret
                                go x = tyErr1 "Cannot apply value as function" x
                            go et


    typecheck (UnsatExpr _) = undefined --saturate (avoiding creation of existing ids) then typecheck
    typecheck (AntiExpr s) = fail $ "Antiquoted expression not provided with explicit signature: " ++ show s

    --TODO: if we're typechecking a function, we can force the type inside the function args
    typecheck (TypeExpr forceType e t)
              | forceType = integrateLocalType t
              | otherwise = do
                            t2 <- typecheck e
                            t1 <- integrateLocalType t
                            t2 <: t1
                            return t1

instance JTypeCheck JVal where
    typecheck (JVar i) =
        case i of
          StrI "true" -> return JTBool
          StrI "false" -> return JTBool
          StrI "null"  -> newTyVar
          StrI _ -> lookupEnv i

    typecheck (JInt _) = return JTNum
    typecheck (JDouble _) = return JTNum
    typecheck (JStr _) = return JTString
    typecheck (JList xs) = typecheck (JHash $ M.fromList $ zip (map show [0..]) xs)
                           -- fmap JTList . someUpperBound =<< mapM typecheck xs
    typecheck (JRegEx _) = undefined --regex object
    typecheck (JHash mp) = JTRecord . M.fromList <$> mapM go (M.toList mp)
        where go (n,v) = (\x -> (n,x)) <$> typecheck v
    typecheck (JFunc args body) = do
                           ((argst',res'), frame) <- withLocalScope $ do
                                           argst <- mapM newVarDecl args
                                           res <- typecheck body
                                           return (argst,res)

                           rt <- resolveType $ JTFunc argst' res'
                           freeVarsInArgs <- S.unions <$> mapM freeVars argst'
                           freeVarsInRes  <- freeVars res'
                           let freeVarsInHeadOrTail = freeVarsInArgs `S.union` freeVarsInRes
                           --everything is frozen that does not appear in the head or tail of a function
                           --TODO we can maybe close a few more, but we must be careful
                           --because anything that *could* appear in both still can't be
                           setFrozen $ frame `S.difference` freeVarsInHeadOrTail

                           -- maybe we can't ever close these up
                           -- addRefsToStack freeVarsInHeadOrTail
                           -- we can close ones which have no way at all to reach the other side

                           tryCloseFrozenVars

                           resolveType $ JTForall (frame2VarRefs frame) rt

    typecheck (UnsatVal _) = undefined --saturate (avoiding creation of existing ids) then typecheck

instance JTypeCheck JStat where
    typecheck (DeclStat ident Nothing) = newVarDecl ident >> return JTStat
    typecheck (DeclStat ident (Just t)) = integrateLocalType t >>= addEnv ident >> return JTStat
    typecheck (ReturnStat e) = typecheck e
    typecheck (IfStat e s s1) = do
                            (<: JTBool) =<< typecheck e
                            t <- typecheck s
                            t1 <- typecheck s1
                            someUpperBound [t,t1] --t /\ t1
    typecheck (WhileStat e s) = do
                            (<: JTBool) =<< typecheck e
                            typecheck s
    typecheck (ForInStat _ _ _ _) = undefined -- yipe!
    typecheck (SwitchStat e xs d) = undefined -- check e, unify e with firsts, check seconds, take glb of seconds
                                    --oh, hey, add typecase to language!?
    typecheck (TryStat _ _ _ _) = undefined -- should be easy
    typecheck (BlockStat xs) = do
                            ts <- mapM typecheckWithBlock xs
                            someUpperBound $ stripStat ts
        where stripStat (JTStat:ts) = stripStat ts
              stripStat (t:ts) = t : stripStat ts
              stripStat t = t
    typecheck (ApplStat args body) = typecheck (ApplExpr args body) >> return JTStat
    typecheck (PostStat s e) = typecheck (PostExpr s e) >> return JTStat
    typecheck (AssignStat e e1) = do
                            t <- typecheck e
                            t1 <- typecheck e1
                            t1 <: t
                            return JTStat
    typecheck (UnsatBlock _) = undefined --oyvey
    typecheck (AntiStat _) = undefined --oyvey
    typecheck BreakStat = return JTStat
    typecheck (ForeignStat i t) = integrateLocalType t >>= addEnv i >> return JTStat

typecheckWithBlock stat = typecheck stat `catchError` \ e -> throwError $ e ++ "\nIn statement:\n" ++ renderStyle (style {mode = OneLineMode}) (renderJs stat)
{-
data JType = JTNum
           | JTString
           | JTBool
           | JTStat
           | JTFunc [JType] (JType)
           | JTList JType --default case is tuple, type sig for list. tuples with <>
           | JTMap  JType
           | JTRecord VarRef [(String, JType)]
           | JTFree VarRef
             deriving (Eq, Ord, Read, Show, Typeable, Data)
-}

{-
    -- | Values
data JVal = JVar     Ident
          | JDouble  Double
          | JInt     Integer
          | JStr     String
          | JList    [JExpr]
          | JRegEx   String
          | JHash    (M.Map String JExpr)
          | JFunc    [Ident] JStat
          | UnsatVal (State [Ident] JVal)
            deriving (Eq, Ord, Show, Data, Typeable)
-}

{-
data JExpr = ValExpr    JVal
           | SelExpr    JExpr Ident
           | IdxExpr    JExpr JExpr
           | InfixExpr  String JExpr JExpr
           | PostExpr   String JExpr
           | IfExpr     JExpr JExpr JExpr
           | NewExpr    JExpr
           | ApplExpr   JExpr [JExpr]
           | UnsatExpr  (State [Ident] JExpr)
           | AntiExpr   String
             deriving (Eq, Ord, Show, Data, Typeable)
-}

{-
--greatest lower bound
-- glb {a:Num} {b:Num} = {a:Num,b:Num}
x \/ y = do
     xt <- resolveType x
     yt <- resolveType y
     if xt == yt
       then return xt
       else go xt yt
  where
    go xt@(JTFree _) yt = do
           ret <- newVarRef
           addConstraint ret (GLB (S.fromList [xt,yt]))
           return (JTFree ret)
    go xt yt@(JTFree _) = go yt xt
    go xt@(JTFunc argsx retx) yt@(JTFunc argsy rety) =
           JTFunc <$> zipWithM (/\) argsx argsy <*> go retx rety
    go (JTList xt) (JTList yt) = JTList <$> go xt yt
    go (JTMap xt) (JTMap yt) = JTMap <$> go xt yt
    go (JTRecord xm) (JTRecord ym) =
        JTRecord <$> T.sequence (M.unionWith (\xt yt -> join $ liftM2 go xt yt) (M.map return xm) (M.map return ym))
    go xt yt
        | xt == yt = return xt
        | otherwise = return JTImpossible

--this can be optimized. split out the free vars, glb the rest, then return a single glb set
glball :: [JType] -> TMonad JType
glball (h:xs) = do
  foldM (\x y -> x \/ y) h xs
glball [] = return JTImpossible

--least upper bound
--lub {a:Num} {a:Num,b:Int} = {a:Num}
x /\ y = do
     xt <- resolveType x
     yt <- resolveType y
     if xt == yt
       then return xt
       else go xt yt
  where
    go xt@(JTFree _) yt = do
           ret <- newVarRef
           addConstraint ret (LUB (S.fromList [xt,yt]))
           return (JTFree ret)
    go xt yt@(JTFree _) = go yt xt
    go xt@(JTFunc argsx retx) yt@(JTFunc argsy rety) =
           JTFunc <$> zipWithOrIdM (\/) argsx argsy <*> go retx rety
    go (JTList xt) (JTList yt) = JTList <$> go xt yt
    go (JTMap xt) (JTMap yt) = JTMap <$> go xt yt
    go (JTRecord xm) (JTRecord ym) = do
        JTRecord <$> T.sequence (M.intersectionWith go xm ym)
    go xt yt
        | xt == yt = return xt
        | otherwise = return JTStat

--this can be optimized. split out the free vars, lub the rest, then return a single lub set
luball :: [JType] -> TMonad JType
luball (h:xs) = do
  foldM (\x y -> x /\ y) h xs
luball [] = return JTStat
-}

{-
resolveConstraints :: Set Int -> TMonad ()
resolveConstraints vrs = mapM_ (resolveConstraint vrs S.empty) $ S.toList vrs

resolveConstraint :: Set Int -> Set Int -> Int -> TMonad ()
resolveConstraint resolvable seen i
    | i `S.member` seen = error "loop" -- not really
    | i `S.member` resolvable = do
             cs <- lookupConstraints (Nothing, i)
             cs' <- mapM reduceConstraint $ S.toList cs
             --now either resolve or error or set
             return ()
    | otherwise = return ()
  where
    reduceConstraint (Sub t) = Sub <$> (resolveConstrainedType <=< resolveType) t
    reduceConstraint (Super t) = Super <$> (resolveConstrainedType <=< resolveType) t
--    reduceConstraint (GLB s) = GLB . S.fromList <$> mapM (resolveConstrainedType <=< resolveType) (S.toList s)
--    reduceConstraint (LUB s) = LUB . S.fromList <$> mapM (resolveConstrainedType <=< resolveType) (S.toList s)

    resolveConstrainedType x = go x
        where go t@(JTFree _) = do
                t' <- resolveType t
                case t' of
                  (JTFree (_,v)) -> do
                                  resolveConstraint resolvable (S.insert i seen) v
                                  resolveType t'
                  _ -> composOpM go t'
              go x = composOpM go x
--func
--record
-}

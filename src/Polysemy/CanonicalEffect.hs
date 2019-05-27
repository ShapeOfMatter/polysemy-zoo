{-# LANGUAGE UndecidableInstances       #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE DerivingVia                #-}
{-|
Module      : PolySemy.CanonicalEffects
Description : Polysemy Class for "absorbing" mtl-style constraints.

Many Polysemy effects are isomoprhic to mtl effects.  In those cases
we ought to be able to "absorb" the mtl effect, as long as it's
specified by a typeclass constraint.  This module contains helpers
to do just that for Reader, Writer, State and Error.

See [test/CanonicalEffect.hs](https://github.com/isovector/polysemy-zoo/tree/master/test/CanonicalEffectSpec.hs) for examples of use.
-}

module Polysemy.CanonicalEffect
  (
    -- * Specific Absorbers
    absorbReader
  , absorbWriter
  , absorbState
  , absorbError
  , absorbRWS

  -- * Generalized Absorber
  , absorbVia

  -- * Individual Wrappers
  , SemReader (..)
  , SemWriter (..)
  , SemState (..)
  , SemError (..)
  , SemRWS (..)

  -- * Helpful type-families
  , ConstrainAllM
  , CanonicalEffects
  , CanonicalEffect 
  )
where

import           Polysemy
import           Polysemy.Reader
import           Polysemy.Writer
import           Polysemy.State
import           Polysemy.Error

import qualified Control.Monad.Reader          as MTL
import qualified Control.Monad.Writer          as MTL
import qualified Control.Monad.State           as MTL
import qualified Control.Monad.Except          as MTL

import           Data.Kind                      ( Type
                                                , Constraint
                                                )

-- | Wrap a Sem for deriving a non-orphan 'MTL.MonadReader' instance via the polysemy 'Reader' effect
newtype SemReader env r a = SemReader { unSemReader :: Sem r a } deriving (Functor, Applicative, Monad)

instance Member (Reader env) r => MTL.MonadReader env (SemReader env r) where
  ask = SemReader ask
  local f = SemReader . local f . unSemReader

-- | re-interpret an 'MTL.MonadReader' constraint via a polysemy 'Reader' Effect 
absorbReader
  :: forall env m r a
   . Member (Reader env) r
  => (forall m . MTL.MonadReader env m => m a)
  -> Sem r a
absorbReader = absorbVia @'[MTL.MonadReader env] (unSemReader :: SemReader env r a -> Sem r a)

-- | Wrap a Sem for deriving a non-orphan 'MTL.MonadWriter' instance via the polysemy 'Writer' effect
newtype SemWriter o r a = SemWriter { unSemWriter :: Sem r a } deriving (Functor, Applicative, Monad)

instance (Monoid o, Member (Writer o) r) => MTL.MonadWriter o (SemWriter o r) where
  tell = SemWriter . tell
  listen = SemWriter . fmap (\(x,y) -> (y,x)) . listen . unSemWriter
  pass x = SemWriter $ do
    (a, f) <- unSemWriter x
    censor f (return a)

-- | re-interpret an 'MTL.MonadWriter' constraint via a polysemy 'Writer' Effect 
absorbWriter
  :: forall w m r a
   . (Monoid w, Member (Writer w) r)
  => (forall m . MTL.MonadWriter w m => m a)
  -> Sem r a
absorbWriter = absorbVia @'[MTL.MonadWriter w] (unSemWriter :: SemWriter w r a -> Sem r a)


-- | Wrap a Sem for deriving a non-orphan 'MTL.MonadState' instance via the polysemy 'State' effect 
newtype SemState s r a = SemState { unSemState :: Sem r a } deriving (Functor, Applicative, Monad)

instance Member (State s) r => MTL.MonadState s (SemState s r) where
  get = SemState get
  put = SemState . put

-- | re-interpret an 'MTL.MonadState' constraint via the polysemy 'State' Effect 
absorbState
  :: forall s m r a
   . Member (State s) r
  => (forall m . MTL.MonadState s m => m a)
  -> Sem r a
absorbState = absorbVia @'[MTL.MonadState s] (unSemState :: SemState s r a -> Sem r a)

-- | Wrap a Sem for deriving a non-orphan 'MTL.MonadError' instance via the polysemy 'Error' effect
newtype SemError e r a = SemError { unSemError :: Sem r a } deriving (Functor, Applicative, Monad)

instance Member (Error e) r => MTL.MonadError e (SemError e r) where
  throwError = SemError . throw
  catchError a h = SemError $ catch (unSemError a) (unSemError . h)

-- | re-interpret an 'MTL.MonadError' constraint via a polysemy 'Error' effect 
absorbError
  :: forall e m r a
   . Member (Error e) r
  => (forall m . MTL.MonadError e m => m a)
  -> Sem r a
absorbError = absorbVia @'[MTL.MonadError e] (unSemError :: SemError e r a -> Sem r a)

---
-- as example and utility
-- | Canonical 
type RWSConstraints env w s = '[MTL.MonadReader env, MTL.MonadWriter w, MTL.MonadState s]

-- | Wrap a Sem for deriving non-orphan RWS instances via polysemy effects
newtype SemRWS (env :: Type) (w :: Type)  (s :: Type) r a = SemRWS { unSemRWS :: Sem r a }
  deriving (Functor, Applicative,Monad) via (Sem r)

deriving via (SemReader (env :: Type) r) instance Member (Reader env) r => MTL.MonadReader env (SemRWS env w s r)
deriving via (SemWriter (w :: Type) r) instance (Monoid w, Member (Writer w) r) => MTL.MonadWriter w (SemRWS env w s r)
deriving via (SemState (s :: Type) r) instance Member (State s) r => MTL.MonadState s (SemRWS env w s r)

-- | re-interpret the RWS constraints via polysemy effects
absorbRWS :: forall env w s r a. (Monoid w, Members [Reader env, Writer w, State s] r)
  => (forall m. ConstrainAllM (RWSConstraints env w s) m => m a) -> Sem r a
absorbRWS = absorbVia @(RWSConstraints env w s) (unSemRWS :: SemRWS env w s r a -> Sem r a)

{- | Turn a type-list of constraints of the form of @(Type -> Type) -> Constraint@
and a single @Type -> Type@ (e.g., a monad)
into a tuple of constraints. That tuple can then be used as an ordinary constraint on the
lhs of a @=>@
-}
type family ConstrainAllM (cs :: [(Type -> Type) -> Constraint]) (m :: Type -> Type) :: Constraint where
  ConstrainAllM (c ': cs') m = (c m, ConstrainAllM cs' m)
  ConstrainAllM '[] _ = ()

{- |
Map a type-list, @cs@, of constraints of the form @(Type -> Type) -> Constraint@
to a list of polysemy effects
required to reinterpret something of the form @(forall m. ConstrainAllM cs m => m a)
as an action in a @Sem r a@ monad, where r has as members all the effects in the list
'CanonicalEffects cs'
-}
type family CanonicalEffects (cs :: [(Type -> Type) -> Constraint]) :: [(Type -> Type) -> Type -> Type] where
  CanonicalEffects (c ': cs') = (CanonicalEffect c ': CanonicalEffects cs')
  CanonicalEffects '[] = '[]

-- This one is open so effects can be added elsewhere
{- | Open type-family mapping a single constraint of the form @(Type -> Type) -> Constraint@, e.g., @MonadState s@,
to a polysemy effect which can be used to re-interpret that constraint, e.g., 'State s'.
-}
type family CanonicalEffect (c :: (Type -> Type) -> Constraint) :: (Type -> Type) -> Type -> Type

type instance  CanonicalEffect (MTL.MonadReader env) = Reader env
type instance  CanonicalEffect (MTL.MonadWriter w) = Writer w
type instance  CanonicalEffect (MTL.MonadState s ) = State s
type instance  CanonicalEffect (MTL.MonadError e)  = Error e

{- | General absorber function, re-interpreting mtl-style constraints via
polysemy effects given a suitable newtype wrapper of Sem.
-}
absorbVia
  :: forall cs r n a
   . (Members (CanonicalEffects cs) r, ConstrainAllM cs n)
  => (n a -> Sem r a)
  -> (forall m . ConstrainAllM cs m => m a)
  -> Sem r a
absorbVia unWrap ma = unWrap ma




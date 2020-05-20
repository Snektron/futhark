{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
module Futhark.Pass.ExplicitAllocations.Seq
       ( explicitAllocations
       , simplifiable
       )
where

import Futhark.Pass
import Futhark.IR.SeqMem
import Futhark.IR.Seq
import Futhark.Pass.ExplicitAllocations

explicitAllocations :: Pass Seq SeqMem
explicitAllocations = explicitAllocationsGeneric (pure . Inner) defaultExpHints

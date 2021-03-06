{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DeriveLift #-}
module Data.Macaw.ARM.Semantics.TH
    ( armAppEvaluator
    , armNonceAppEval
    , getGPR
    , setGPR
    , getSIMD
    , setSIMD
    , loadSemantics
    )
    where

import           Control.Monad ( join, void )
import qualified Control.Monad.Except as E
import qualified Data.BitVector.Sized as BVS
import           Data.List (isPrefixOf)
import           Data.Macaw.ARM.ARMReg
import           Data.Macaw.ARM.Arch
import qualified Data.Macaw.CFG as M
import qualified Data.Macaw.SemMC.Generator as G
import           Data.Macaw.SemMC.TH ( addEltTH, natReprTH, symFnName )
import           Data.Macaw.SemMC.TH.Monad
import qualified Data.Macaw.Types as M
import           Data.Parameterized.Classes
import qualified Data.Parameterized.Classes as PC
import qualified Data.Parameterized.Context as Ctx
import           Data.Parameterized.NatRepr
import           GHC.TypeLits as TL
import qualified Lang.Crucible.Backend.Simple as CBS
import           Language.Haskell.TH
import           Language.Haskell.TH.Syntax
import qualified SemMC.Architecture.AArch32 as ARM
import qualified SemMC.Architecture.ARM.Opcodes as ARM
import qualified What4.BaseTypes as WT
import qualified What4.Expr.Builder as WB

import qualified Language.ASL.Globals as ASL

import           Data.Macaw.ARM.Simplify ()

loadSemantics :: CBS.SimpleBackend t fs -> IO (ARM.ASLSemantics (CBS.SimpleBackend t fs))
loadSemantics sym = ARM.loadSemantics sym (ARM.ASLSemanticsOpts { ARM.aslOptTrimRegs = True})

-- n.b. although MacawQ is a monad and therefore has a fail
-- definition, using error provides *much* better error diagnostics
-- than fail does.

-- | Called to evaluate architecture-specific applications in the
-- current Nonce context.  If this is not recognized as an
-- architecture-specific Application, return Nothing, in which case
-- the caller will try the set of default Application evaluators.
armNonceAppEval :: forall t fs tp
                  . BoundVarInterpretations ARM.AArch32 t fs
                 -> WB.NonceApp t (WB.Expr t) tp
                 -> Maybe (MacawQ ARM.AArch32 t fs Exp)
armNonceAppEval bvi nonceApp =
    -- The default nonce app eval (defaultNonceAppEvaluator in
    -- macaw-semmc:Data.Macaw.SemMC.TH) will search the
    -- A.locationFuncInterpretation alist already, and there's nothing
    -- beyond that needed here, so just handle special cases here
    case nonceApp of
      WB.FnApp symFn args ->
        let fnName = symFnName symFn
            tp = WB.symFnReturnType symFn
        in case fnName of
          "uf_simd_set" ->
            case args of
              Ctx.Empty Ctx.:> rgf Ctx.:> rid Ctx.:> val -> Just $ do
                rgfE <- addEltTH M.LittleEndian bvi rgf
                ridE <- addEltTH M.LittleEndian bvi rid
                valE <- addEltTH M.LittleEndian bvi val
                liftQ [| join (setSIMD <$> $(refBinding rgfE) <*> $(refBinding ridE) <*> $(refBinding valE)) |]
              _ -> fail "Invalid uf_simd_get"
          "uf_gpr_set" ->
            case args of
              Ctx.Empty Ctx.:> rgf Ctx.:> rid Ctx.:> val -> Just $ do
                rgfE <- addEltTH M.LittleEndian bvi rgf
                ridE <- addEltTH M.LittleEndian bvi rid
                valE <- addEltTH M.LittleEndian bvi val
                liftQ [| join (setGPR <$> $(refBinding rgfE) <*> $(refBinding ridE) <*> $(refBinding valE)) |]
              _ -> fail "Invalid uf_gpr_get"
          "uf_simd_get" ->
            case args of
              Ctx.Empty Ctx.:> array Ctx.:> ix ->
                Just $ do
                  _rgf <- addEltTH M.LittleEndian bvi array
                  rid <- addEltTH M.LittleEndian bvi ix
                  liftQ [| getSIMD =<< $(refBinding rid) |]
              _ -> fail "Invalid uf_simd_get"
          "uf_gpr_get" ->
            case args of
              Ctx.Empty Ctx.:> array Ctx.:> ix ->
                Just $ do
                  _rgf <- addEltTH M.LittleEndian bvi array
                  rid <- addEltTH M.LittleEndian bvi ix
                  liftQ [| getGPR =<< $(refBinding rid) |]
              _ -> fail "Invalid uf_gpr_get"
          _ | "uf_write_mem_" `isPrefixOf` fnName ->
            case args of
              Ctx.Empty Ctx.:> mem Ctx.:> addr Ctx.:> val
               | WT.BaseBVRepr memWidthRepr <- WB.exprType val ->
                 Just $ do
                memE <- addEltTH M.LittleEndian bvi mem
                addrE <- addEltTH M.LittleEndian bvi addr
                valE <- addEltTH M.LittleEndian bvi val
                let memWidth = fromIntegral (intValue memWidthRepr) `div` 8
                liftQ [| join (writeMem <$> $(refBinding memE) <*> $(refBinding addrE) <*> pure $(natReprFromIntTH memWidth) <*> $(refBinding valE)) |]
              _ -> fail "invalid write_mem"



          _ | "uf_unsignedRSqrtEstimate" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op -> Just $ do
                  ope <- addEltTH M.LittleEndian bvi op
                  liftQ [| G.addExpr =<< (UnsignedRSqrtEstimate knownNat <$> $(refBinding ope)) |]
                _ -> fail "Invalid unsignedRSqrtEstimate arguments"

          -- NOTE: This must come before fpMul, since fpMul is a prefix of this
          _ | "uf_fpMulAdd" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> op2 Ctx.:> op3 Ctx.:> fpcr -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  op2e <- addEltTH M.LittleEndian bvi op2
                  op3e <- addEltTH M.LittleEndian bvi op3
                  fpcre <- addEltTH M.LittleEndian bvi fpcr
                  liftQ [| G.addExpr =<< (FPMulAdd knownNat <$> $(refBinding op1e) <*> $(refBinding op2e) <*> $(refBinding op3e) <*> $(refBinding fpcre)) |]
                _ -> fail "Invalid fpMulAdd arguments"


          _ | "uf_fpSub" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> op2 Ctx.:> fpcr -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  op2e <- addEltTH M.LittleEndian bvi op2
                  fpcre <- addEltTH M.LittleEndian bvi fpcr
                  liftQ [| G.addExpr =<< (FPSub knownNat <$> $(refBinding op1e) <*> $(refBinding op2e) <*> $(refBinding fpcre)) |]
                _ -> fail "Invalid fpSub arguments"
          _ | "uf_fpAdd" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> op2 Ctx.:> fpcr -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  op2e <- addEltTH M.LittleEndian bvi op2
                  fpcre <- addEltTH M.LittleEndian bvi fpcr
                  liftQ [| G.addExpr =<< (FPAdd knownNat <$> $(refBinding op1e) <*> $(refBinding op2e) <*> $(refBinding fpcre)) |]
                _ -> fail "Invalid fpAdd arguments"
          _ | "uf_fpMul" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> op2 Ctx.:> fpcr -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  op2e <- addEltTH M.LittleEndian bvi op2
                  fpcre <- addEltTH M.LittleEndian bvi fpcr
                  liftQ [| G.addExpr =<< (FPMul knownNat <$> $(refBinding op1e) <*> $(refBinding op2e) <*> $(refBinding fpcre)) |]
                _ -> fail "Invalid fpMul arguments"
          _ | "uf_fpDiv" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> op2 Ctx.:> fpcr -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  op2e <- addEltTH M.LittleEndian bvi op2
                  fpcre <- addEltTH M.LittleEndian bvi fpcr
                  liftQ [| G.addExpr =<< (FPMul knownNat <$> $(refBinding op1e) <*> $(refBinding op2e) <*> $(refBinding fpcre)) |]
                _ -> fail "Invalid fpDiv arguments"

          _ | "uf_fpMaxNum" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> op2 Ctx.:> fpcr -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  op2e <- addEltTH M.LittleEndian bvi op2
                  fpcre <- addEltTH M.LittleEndian bvi fpcr
                  liftQ [| G.addExpr =<< (FPMaxNum knownNat <$> $(refBinding op1e) <*> $(refBinding op2e) <*> $(refBinding fpcre)) |]
                _ -> fail "Invalid fpMaxNum arguments"
          _ | "uf_fpMinNum" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> op2 Ctx.:> fpcr -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  op2e <- addEltTH M.LittleEndian bvi op2
                  fpcre <- addEltTH M.LittleEndian bvi fpcr
                  liftQ [| G.addExpr =<< (FPMinNum knownNat <$> $(refBinding op1e) <*> $(refBinding op2e) <*> $(refBinding fpcre)) |]
                _ -> fail "Invalid fpMinNum arguments"
          _ | "uf_fpMax" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> op2 Ctx.:> fpcr -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  op2e <- addEltTH M.LittleEndian bvi op2
                  fpcre <- addEltTH M.LittleEndian bvi fpcr
                  liftQ [| G.addExpr =<< (FPMax knownNat <$> $(refBinding op1e) <*> $(refBinding op2e) <*> $(refBinding fpcre)) |]
                _ -> fail "Invalid fpMax arguments"
          _ | "uf_fpMin" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> op2 Ctx.:> fpcr -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  op2e <- addEltTH M.LittleEndian bvi op2
                  fpcre <- addEltTH M.LittleEndian bvi fpcr
                  liftQ [| G.addExpr =<< (FPMin knownNat <$> $(refBinding op1e) <*> $(refBinding op2e) <*> $(refBinding fpcre)) |]
                _ -> fail "Invalid fpMin arguments"

          _ | "uf_fpRecipEstimate" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> fpcr -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  fpcre <- addEltTH M.LittleEndian bvi fpcr
                  liftQ [| G.addExpr =<< (FPRecipEstimate knownNat <$> $(refBinding op1e) <*> $(refBinding fpcre)) |]
                _ -> fail "Invalid fpRecipEstimate arguments"
          _ | "uf_fpRecipStep" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> fpcr -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  fpcre <- addEltTH M.LittleEndian bvi fpcr
                  liftQ [| G.addExpr =<< (FPRecipStep knownNat <$> $(refBinding op1e) <*> $(refBinding fpcre)) |]
                _ -> fail "Invalid fpRecipStep arguments"
          _ | "uf_fpSqrtEstimate" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> fpcr -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  fpcre <- addEltTH M.LittleEndian bvi fpcr
                  liftQ [| G.addExpr =<< (FPSqrtEstimate knownNat <$> $(refBinding op1e) <*> $(refBinding fpcre)) |]
                _ -> fail "Invalid fpSqrtEstimate arguments"
          _ | "uf_fprSqrtStep" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> fpcr -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  fpcre <- addEltTH M.LittleEndian bvi fpcr
                  liftQ [| G.addExpr =<< (FPRSqrtStep knownNat <$> $(refBinding op1e) <*> $(refBinding fpcre)) |]
                _ -> fail "Invalid fprSqrtStep arguments"
          _ | "uf_fpSqrt" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> fpcr -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  fpcre <- addEltTH M.LittleEndian bvi fpcr
                  liftQ [| G.addExpr =<< (FPSqrt knownNat <$> $(refBinding op1e) <*> $(refBinding fpcre)) |]
                _ -> fail "Invalid fpSqrt arguments"

          _ | "uf_fpCompareGE" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> op2 Ctx.:> fpcr -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  op2e <- addEltTH M.LittleEndian bvi op2
                  fpcre <- addEltTH M.LittleEndian bvi fpcr
                  liftQ [| G.addExpr =<< (FPCompareGE knownNat <$> $(refBinding op1e) <*> $(refBinding op2e) <*> $(refBinding fpcre)) |]
                _ -> fail "Invalid fpCompareGE arguments"
          _ | "uf_fpCompareGT" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> op2 Ctx.:> fpcr -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  op2e <- addEltTH M.LittleEndian bvi op2
                  fpcre <- addEltTH M.LittleEndian bvi fpcr
                  liftQ [| G.addExpr =<< (FPCompareGT knownNat <$> $(refBinding op1e) <*> $(refBinding op2e) <*> $(refBinding fpcre)) |]
                _ -> fail "Invalid fpCompareGT arguments"
          _ | "uf_fpCompareEQ" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> op2 Ctx.:> fpcr -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  op2e <- addEltTH M.LittleEndian bvi op2
                  fpcre <- addEltTH M.LittleEndian bvi fpcr
                  liftQ [| G.addExpr =<< (FPCompareEQ knownNat <$> $(refBinding op1e) <*> $(refBinding op2e) <*> $(refBinding fpcre)) |]
                _ -> fail "Invalid fpCompareEQ arguments"
          _ | "uf_fpCompareNE" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> op2 Ctx.:> fpcr -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  op2e <- addEltTH M.LittleEndian bvi op2
                  fpcre <- addEltTH M.LittleEndian bvi fpcr
                  liftQ [| G.addExpr =<< (FPCompareNE knownNat <$> $(refBinding op1e) <*> $(refBinding op2e) <*> $(refBinding fpcre)) |]
                _ -> fail "Invalid fpCompareNE arguments"
          _ | "uf_fpCompareUN" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> op2 Ctx.:> fpcr -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  op2e <- addEltTH M.LittleEndian bvi op2
                  fpcre <- addEltTH M.LittleEndian bvi fpcr
                  liftQ [| G.addExpr =<< (FPCompareUN knownNat <$> $(refBinding op1e) <*> $(refBinding op2e) <*> $(refBinding fpcre)) |]
                _ -> fail "Invalid fpCompareUN arguments"

          "uf_fpToFixedJS" ->
            case args of
              Ctx.Empty Ctx.:> op1 Ctx.:> op2 Ctx.:> op3 -> Just $ do
                op1e <- addEltTH M.LittleEndian bvi op1
                op2e <- addEltTH M.LittleEndian bvi op2
                op3e <- addEltTH M.LittleEndian bvi op3
                liftQ [| G.addExpr =<< (FPToFixedJS <$> $(refBinding op1e) <*> $(refBinding op2e) <*> $(refBinding op3e)) |]
              _ -> fail "Invalid fpToFixedJS arguments"
          _ | "uf_fpToFixed" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> op2 Ctx.:> op3 Ctx.:> op4 Ctx.:> op5 -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  op2e <- addEltTH M.LittleEndian bvi op2
                  op3e <- addEltTH M.LittleEndian bvi op3
                  op4e <- addEltTH M.LittleEndian bvi op4
                  op5e <- addEltTH M.LittleEndian bvi op5
                  liftQ [| G.addExpr =<< (FPToFixed knonwNat <$> $(refBinding op1e) <*> $(refBinding op2e) <*> $(refBinding op3e) <*> $(refBinding op4e) <*> $(refBinding op5e)) |]
                _ -> fail "Invalid fpToFixed arguments"
          _ | "uf_fixedToFP" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> op2 Ctx.:> op3 Ctx.:> op4 Ctx.:> op5 -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  op2e <- addEltTH M.LittleEndian bvi op2
                  op3e <- addEltTH M.LittleEndian bvi op3
                  op4e <- addEltTH M.LittleEndian bvi op4
                  op5e <- addEltTH M.LittleEndian bvi op5
                  liftQ [| G.addExpr =<< (FixedToFP knonwNat <$> $(refBinding op1e) <*> $(refBinding op2e) <*> $(refBinding op3e) <*> $(refBinding op4e) <*> $(refBinding op5e)) |]
                _ -> fail "Invalid fixedToFP arguments"
          _ | "uf_fpConvert" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> op2 Ctx.:> op3 -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  op2e <- addEltTH M.LittleEndian bvi op2
                  op3e <- addEltTH M.LittleEndian bvi op3
                  liftQ [| G.addExpr =<< (FPConvert knownNat <$> $(refBinding op1e) <*> $(refBinding op2e) <*> $(refBinding op3e)) |]
                _ -> fail "Invalid fpConvert arguments"
          _ | "uf_fpRoundInt" `isPrefixOf` fnName ->
              case args of
                Ctx.Empty Ctx.:> op1 Ctx.:> op2 Ctx.:> op3 Ctx.:> op4 -> Just $ do
                  op1e <- addEltTH M.LittleEndian bvi op1
                  op2e <- addEltTH M.LittleEndian bvi op2
                  op3e <- addEltTH M.LittleEndian bvi op3
                  op4e <- addEltTH M.LittleEndian bvi op4
                  liftQ [| G.addExpr =<< (FPRoundInt knownNat <$> $(refBinding op1e) <*> $(refBinding op2e) <*> $(refBinding op3e) <*> $(refBinding op4e)) |]
                _ -> fail "Invalid fpRoundInt arguments"

          -- NOTE: These three cases occasionally end up unused.  Because we let
          -- bind almost everything, that can lead to the 'arch' type parameter
          -- being ambiguous, which is an error for various reasons.
          --
          -- To fix that, we add an explicit type application here.
          "uf_init_gprs" -> Just $ liftQ [| M.AssignedValue <$> G.addAssignment @ARM.AArch32 (M.SetUndefined $(what4TypeTH tp)) |]
          "uf_init_memory" -> Just $ liftQ [| M.AssignedValue <$> G.addAssignment @ARM.AArch32 (M.SetUndefined $(what4TypeTH tp)) |]
          "uf_init_simds" -> Just $ liftQ [| M.AssignedValue <$> G.addAssignment @ARM.AArch32 (M.SetUndefined $(what4TypeTH tp)) |]


          -- NOTE: These cases are tricky because they generate groups of
          -- statements that need to behave a bit differently in (eager)
          -- top-level code generation and (lazy) conditional code generation.
          --
          -- In either case, the calls to 'setWriteMode' /must/ bracket the
          -- memory/register update function.
          --
          -- In the eager translation case, that means that we have to lexically
          -- emit the update between the write mode guards (so that the effect
          -- actually happens).
          --
          -- In contrast, the lazy translation case has to emit the write
          -- operation as a lazy let binding to preserve sharing, but group all
          -- three statements in the actual 'Generator' monad.
          "uf_update_gprs"
            | Ctx.Empty Ctx.:> gprs <- args -> Just $ do
              istl <- isTopLevel
              case istl of
                False -> do
                  gprs' <- addEltTH M.LittleEndian bvi gprs
                  liftQ [| do setWriteMode WriteGPRs
                              $(refBinding gprs')
                              setWriteMode WriteNone
                         |]
                True -> do
                  appendStmt [| setWriteMode WriteGPRs |]
                  gprs' <- addEltTH M.LittleEndian bvi gprs
                  appendStmt [| setWriteMode WriteNone |]
                  extractBound gprs'
          "uf_update_simds"
            | Ctx.Empty Ctx.:> simds <- args -> Just $ do
                istl <- isTopLevel
                case istl of
                  False -> do
                    simds' <- addEltTH M.LittleEndian bvi simds
                    liftQ [| do setWriteMode WriteSIMDs
                                $(refBinding simds')
                                setWriteMode WriteNone
                           |]
                  True -> do
                    appendStmt [| setWriteMode WriteSIMDs |]
                    simds' <- addEltTH M.LittleEndian bvi simds
                    appendStmt [| setWriteMode WriteNone |]
                    extractBound simds'
          "uf_update_memory"
            | Ctx.Empty Ctx.:> mem <- args -> Just $ do
                istl <- isTopLevel
                case istl of
                  False -> do
                    mem' <- addEltTH M.LittleEndian bvi mem
                    liftQ [| do setWriteMode WriteMemory
                                $(refBinding mem')
                                setWriteMode WriteNone
                           |]
                  True -> do
                    appendStmt [| setWriteMode WriteMemory |]
                    mem' <- addEltTH M.LittleEndian bvi mem
                    appendStmt [| setWriteMode WriteNone |]
                    extractBound mem'

          _ | "uf_assertBV_" `isPrefixOf` fnName ->
            case args of
              Ctx.Empty Ctx.:> assert Ctx.:> bv -> Just $ do
                assertTH <- addEltTH M.LittleEndian bvi assert
                bvElt <- addEltTH M.LittleEndian bvi bv
                liftQ [| case $(refBinding assertTH) of
                          M.BoolValue True -> return $(refBinding bvElt)
                          M.BoolValue False -> E.throwError (G.GeneratorMessage $ "Bitvector length assertion failed!")
                          -- FIXME: THIS SHOULD THROW AN ERROR
                          _ -> return $(refBinding bvElt)
                          -- nm -> E.throwError (G.GeneratorMessage $ "Bitvector length assertion failed: <FIXME: PRINT NAME>")
                       |]
              _ -> fail "Invalid call to assertBV"

          _ | "uf_UNDEFINED_" `isPrefixOf` fnName ->
               Just $ liftQ [| M.AssignedValue <$> G.addAssignment (M.SetUndefined $(what4TypeTH tp)) |]
          _ | "uf_INIT_GLOBAL_" `isPrefixOf` fnName ->
               Just $ liftQ [| M.AssignedValue <$> G.addAssignment (M.SetUndefined $(what4TypeTH tp)) |]
          _ -> Nothing
      _ -> Nothing -- fallback to default handling

natReprFromIntTH :: Int -> Q Exp
natReprFromIntTH i = [| knownNat :: M.NatRepr $(litT (numTyLit (fromIntegral i))) |]

data WriteMode =
  WriteNone
  | WriteGPRs
  | WriteSIMDs
  | WriteMemory
  deriving (Show, Eq, Lift)

getWriteMode :: G.Generator ARM.AArch32 ids s WriteMode
getWriteMode = do
  G.getRegVal ARMWriteMode >>= \case
      M.BVValue _ i -> return $ case i of
        0 -> WriteNone
        1 -> WriteGPRs
        2 -> WriteSIMDs
        3 -> WriteMemory
        _ -> error "impossible"
      _ -> error "impossible"

setWriteMode :: WriteMode -> G.Generator ARM.AArch32 ids s ()
setWriteMode wm =
  let
    i = case wm of
      WriteNone -> 0
      WriteGPRs -> 1
      WriteSIMDs -> 2
      WriteMemory -> 3
  in G.setRegVal ARMWriteMode (M.BVValue knownNat i)

writeMem :: 1 <= w
         => M.Value ARM.AArch32 ids tp
         -> M.Value ARM.AArch32 ids (M.BVType 32)
         -> M.NatRepr w
         -> M.Value ARM.AArch32 ids (M.BVType (8 TL.* w))
         -> G.Generator ARM.AArch32 ids s (M.Value ARM.AArch32 ids tp)
writeMem mem addr sz val = do
  wm <- getWriteMode
  case wm of
    WriteMemory -> do
      G.addStmt (M.WriteMem addr (M.BVMemRepr sz M.LittleEndian) val)
      return mem
    _ -> return mem

setGPR :: M.Value ARM.AArch32 ids tp
       -> M.Value ARM.AArch32 ids (M.BVType 4)
       -> M.Value ARM.AArch32 ids (M.BVType 32)
       -> G.Generator ARM.AArch32 ids s (M.Value ARM.AArch32 ids tp)
setGPR handle regid v = do
  reg <- case regid of
    M.BVValue w i
      | intValue w == 4
      , Just reg <- integerToReg i -> return reg
    _ -> E.throwError (G.GeneratorMessage $ "Bad GPR identifier (uf_gpr_set): " <> show (M.ppValueAssignments v))
  getWriteMode >>= \case
    WriteGPRs -> G.setRegVal reg v
    _ -> return ()
  return handle

getGPR :: M.Value ARM.AArch32 ids tp
       -> G.Generator ARM.AArch32 ids s (M.Value ARM.AArch32 ids (M.BVType 32))
getGPR v = do
  reg <- case v of
    M.BVValue w i
      | intValue w == 4
      , Just reg <- integerToReg i -> return reg
    _ ->  E.throwError (G.GeneratorMessage $ "Bad GPR identifier (uf_gpr_get): " <> show (M.ppValueAssignments v))
  G.getRegSnapshotVal reg

setSIMD :: M.Value ARM.AArch32 ids tp
       -> M.Value ARM.AArch32 ids (M.BVType 8)
       -> M.Value ARM.AArch32 ids (M.BVType 128)
       -> G.Generator ARM.AArch32 ids s (M.Value ARM.AArch32 ids tp)
setSIMD handle regid v = do
  reg <- case regid of
    M.BVValue w i
      | intValue w == 8
      , Just reg <- integerToSIMDReg i -> return reg
    _ -> E.throwError (G.GeneratorMessage $ "Bad SIMD identifier (uf_simd_set): " <> show (M.ppValueAssignments v))
  getWriteMode >>= \case
    WriteSIMDs -> G.setRegVal reg v
    _ -> return ()
  return handle

getSIMD :: M.Value ARM.AArch32 ids tp
       -> G.Generator ARM.AArch32 ids s (M.Value ARM.AArch32 ids (M.BVType 128))
getSIMD v = do
  reg <- case v of
    M.BVValue w i
      | intValue w == 8
      , Just reg <- integerToSIMDReg i -> return reg
    _ ->  E.throwError (G.GeneratorMessage $ "Bad SIMD identifier (uf_simd_get): " <> show (M.ppValueAssignments v))
  G.getRegVal reg

what4TypeTH :: WT.BaseTypeRepr tp -> Q Exp
what4TypeTH (WT.BaseBVRepr natRepr) = [| M.BVTypeRepr $(natReprTH natRepr) |]
what4TypeTH WT.BaseBoolRepr = [| M.BoolTypeRepr |]
what4TypeTH tp = error $ "Unsupported base type: " <> show tp


-- ----------------------------------------------------------------------

-- ----------------------------------------------------------------------

addArchAssignment :: (M.HasRepr (M.ArchFn ARM.AArch32 (M.Value ARM.AArch32 ids)) M.TypeRepr)
                  => M.ArchFn ARM.AArch32 (M.Value ARM.AArch32 ids) tp
                  -> G.Generator ARM.AArch32 ids s (G.Expr ARM.AArch32 ids tp)
addArchAssignment expr = (G.ValueExpr . M.AssignedValue) <$> G.addAssignment (M.EvalArchFn expr (M.typeRepr expr))


-- | indicates that this is a placeholder type (i.e. memory or registers)
isPlaceholderType :: WT.BaseTypeRepr tp -> Bool
isPlaceholderType tp = case tp of
  _ | Just Refl <- testEquality tp (knownRepr :: WT.BaseTypeRepr ASL.MemoryBaseType) -> True
  _ | Just Refl <- testEquality tp (knownRepr :: WT.BaseTypeRepr ASL.AllGPRBaseType) -> True
  _ | Just Refl <- testEquality tp (knownRepr :: WT.BaseTypeRepr ASL.AllSIMDBaseType) -> True
  _ -> False

-- | This combinator provides conditional evaluation of its branches
--
-- Many conditionals in the semantics are translated as muxes (effectively
-- if-then-else expressions).  This is great most of the time, but problematic
-- if the branches include side effects (e.g., memory writes).  We only want
-- side effects to happen if the condition really is true.
--
-- This combinator checks to see if the condition is concretely true or false
-- (as expected) and then evaluates the corresponding 'G.Generator' action.
--
-- It is meant to be used in a context like:
--
-- > val <- concreteIte condition trueThings falseThings
--
-- where @condition@ has type Value and the branches have type 'G.Generator'
-- 'M.Value' (i.e., the branches get to return a value).
--
-- NOTE: This function panics (and throws an error) if the argument is not
-- concrete.
concreteIte :: M.TypeRepr tp
            -> M.Value ARM.AArch32 ids (M.BoolType)
            -> G.Generator ARM.AArch32 ids s (M.Value ARM.AArch32 ids tp)
            -> G.Generator ARM.AArch32 ids s (M.Value ARM.AArch32 ids tp)
            -> G.Generator ARM.AArch32 ids s (M.Value ARM.AArch32 ids tp)
concreteIte rep v t f = case v of
  M.CValue (M.BoolCValue b) -> if b then t else f
  _ -> G.addExpr =<< G.AppExpr <$> (M.Mux rep v <$> t <*> f)

-- | A smart constructor for division
--
-- The smart constructor recognizes divisions that can be converted into shifts.
-- We convert the operation to a shift if the divisior is a power of two.
sdiv :: (1 <= n)
     => NatRepr n
     -> M.Value ARM.AArch32 ids (M.BVType n)
     -> M.Value ARM.AArch32 ids (M.BVType n)
     -> G.Generator ARM.AArch32 ids s (G.Expr ARM.AArch32 ids (M.BVType n))
sdiv repr dividend divisor =
  case divisor of
    M.BVValue nr val
      | bv <- BVS.mkBV repr val
      , BVS.asUnsigned (BVS.popCount bv) == 1 ->
        withKnownNat repr $
          let app = M.BVSar nr dividend (M.BVValue nr (BVS.asUnsigned (BVS.ctz repr bv)))
          in G.ValueExpr <$> G.addExpr (G.AppExpr app)
    _ -> addArchAssignment (SDiv repr dividend divisor)

armAppEvaluator :: M.Endianness
                -> BoundVarInterpretations ARM.AArch32 t fs
                -> WB.App (WB.Expr t) ctp
                -> Maybe (MacawQ ARM.AArch32 t fs Exp)
armAppEvaluator endianness interps elt =
    case elt of
      WB.BaseIte bt _ test t f | isPlaceholderType bt -> return $ do
        -- NOTE: This case is very special.  The placeholder types denote
        -- conditionals that are guarding the state update functions with
        -- mutation.
        --
        -- We need to ensure that state updates are only done lazily.  This
        -- works because the arguments to the branches are expressions in the
        -- Generator monad.  We can do this translation while preserving sharing
        -- by turning every recursively-traversed term into a let binding at the
        -- top-level.  After that, we can build bodies for the "arms" of the
        -- concreteIte that instantiate those terms in the appropriate monadic
        -- context.  It is slightly problematic that the core TH translation
        -- doesn't really support that because it wants to (more efficiently)
        -- evaluate all of the monadic stuff.  However, we don't need quite as
        -- much generality for this code, so maybe a smaller core that just does
        -- all of the necessary applicative binding of 'Generator' terms will be
        -- sufficient.
        testE <- addEltTH endianness interps test
        inConditionalContext $ do
          tE <- addEltTH endianness interps t
          fE <- addEltTH endianness interps f
          liftQ [| join (concreteIte PC.knownRepr <$> $(refBinding testE) <*> (return $(refBinding tE)) <*> (return $(refBinding fE))) |]
      WB.BVSdiv w bv1 bv2 -> return $ do
        e1 <- addEltTH endianness interps bv1
        e2 <- addEltTH endianness interps bv2
        liftQ [| G.addExpr =<< join (sdiv $(natReprTH w) <$> $(refBinding e1) <*> $(refBinding e2)) |]
      WB.BVUrem w bv1 bv2 -> return $ do
        e1 <- addEltTH endianness interps bv1
        e2 <- addEltTH endianness interps bv2
        liftQ [| G.addExpr =<< join (addArchAssignment <$> (URem $(natReprTH w) <$> $(refBinding e1) <*> $(refBinding e2)))
               |]
      WB.BVSrem w bv1 bv2 -> return $ do
        e1 <- addEltTH endianness interps bv1
        e2 <- addEltTH endianness interps bv2
        liftQ [| G.addExpr =<< join (addArchAssignment <$> (SRem $(natReprTH w) <$> $(refBinding e1) <*> $(refBinding e2)))
               |]
      WB.IntegerToBV _ _ -> return $ liftQ [| error "IntegerToBV" |]
      WB.SBVToInteger _ -> return $ liftQ [| error "SBVToInteger" |]
      WB.BaseIte bt _ test t f ->
        case bt of
          WT.BaseArrayRepr {} -> Just $ do
            -- Just return the true branch, since both true and false branches should be the memory or registers.
            void $ addEltTH endianness interps test
            et <- addEltTH endianness interps t
            void $ addEltTH endianness interps f
            extractBound et
          _ -> Nothing
      _ -> Nothing

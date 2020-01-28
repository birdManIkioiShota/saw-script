module SAWScript.Prover.ABC (proveABC, proveABCExternal) where


import qualified Data.AIG as AIG

import           Verifier.SAW.SharedTerm
import           Verifier.SAW.TypedTerm
import           Verifier.SAW.FiniteValue
import qualified Verifier.SAW.Simulator.BitBlast as BBSim

import SAWScript.Proof(Prop, propToPredicate, unProp)
import SAWScript.Prover.Exporter (writeVerilogProp)
import SAWScript.Prover.SolverStats (SolverStats, solverStats)
import SAWScript.Prover.Rewrite(rewriteEqs)
import SAWScript.SAWCorePrimitives( bitblastPrimitives )
import SAWScript.Prover.Util
         (liftCexBB, bindAllExts, checkBooleanSchema)

-- | Bit-blast a proposition and check its validity using ABC.
proveABC ::
  (AIG.IsAIG l g) =>
  AIG.Proxy l g ->
  SharedContext ->
  Prop ->
  IO (Maybe [(String, FirstOrderValue)], SolverStats)
proveABC proxy sc goal =
  do t0 <- propToPredicate sc goal
     TypedTerm schema t <-
        (bindAllExts sc t0 >>= rewriteEqs sc >>= mkTypedTerm sc)
     checkBooleanSchema schema
     BBSim.withBitBlastedPred proxy sc bitblastPrimitives t $
      \be lit0 shapes ->
         do let lit = AIG.not lit0
            satRes <- getModel (map fst shapes) (map snd shapes) =<< AIG.checkSat be lit
            let stats = solverStats "ABC" (scSharedSize t0)
            return (satRes, stats)


getModel ::
  Show name =>
  [name] ->
  [FiniteType] ->
  AIG.SatResult ->
  IO (Maybe [(name, FirstOrderValue)])
getModel argNames shapes satRes =
  case satRes of
    AIG.Unsat -> return Nothing

    AIG.Sat cex -> do
      case liftCexBB shapes cex of
        Left err -> fail ("Can't parse counterexample: " ++ err)
        Right vs

          | length argNames == length vs ->
            return (Just (zip argNames (map toFirstOrderValue vs)))

          | otherwise ->
              fail $ unwords [ "ABC SAT results do not match expected arguments"
                             , show argNames, show vs]

    AIG.SatUnknown -> fail "Unknown result from ABC"


-- | Check the satisfiability of a @Term@ using ABC as an external
-- process.
proveABCExternal ::
  SharedContext ->
  Prop ->
  IO (Maybe [(String,FirstOrderValue)], SolverStats)
proveABCExternal sc goal =
  do let file = undefined
         stats = solverStats "ABCExternal" (scSharedSize (unProp goal))
     writeVerilogProp sc file goal
     -- TODO: invoke ABC and parse output
     return (Nothing, stats)

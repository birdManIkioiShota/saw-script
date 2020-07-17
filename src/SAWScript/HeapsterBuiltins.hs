{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE KindSignatures #-}

module SAWScript.HeapsterBuiltins
       ( heapster_init_env
       , heapster_init_env_from_file
       , heapster_init_env_for_files
       , heapster_typecheck_fun
       , heapster_typecheck_mut_funs
       , heapster_define_opaque_perm
       , heapster_define_recursive_perm
       , heapster_define_perm
       , heapster_block_entry_hint
       , heapster_assume_fun
       , heapster_print_fun_trans
       , heapster_export_coq
       , heapster_parse_test
       ) where

import Data.Maybe
import qualified Data.Map as Map
import Data.String
import Data.List
import Data.IORef
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Fail (MonadFail)
import qualified Control.Monad.Fail as Fail
import Unsafe.Coerce
import System.Directory
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.UTF8 as BL

import Data.Binding.Hobbits

import qualified Data.Parameterized.Context as Ctx
import Data.Parameterized.TraversableFC

import Verifier.SAW.Term.Functor
import Verifier.SAW.Module
import Verifier.SAW.Prelude
import Verifier.SAW.SharedTerm
import Verifier.SAW.OpenTerm
import Verifier.SAW.Typechecker
import Verifier.SAW.SCTypeCheck
import qualified Verifier.SAW.UntypedAST as Un
import qualified Verifier.SAW.Grammar as Un

import Lang.Crucible.Types
import Lang.Crucible.FunctionHandle
import Lang.Crucible.CFG.Core
import Lang.Crucible.LLVM.Extension
import Lang.Crucible.LLVM.MemModel
import Lang.Crucible.LLVM.Translation

import qualified Text.LLVM.AST as L

import SAWScript.TopLevel
import SAWScript.Value
import SAWScript.Options
import SAWScript.LLVMBuiltins
import SAWScript.Builtins
import SAWScript.Crucible.LLVM.Builtins
import SAWScript.Crucible.LLVM.MethodSpecIR

import Verifier.SAW.Heapster.CruUtil
import Verifier.SAW.Heapster.Permissions
import Verifier.SAW.Heapster.SAWTranslation
import Verifier.SAW.Heapster.PermParser

import SAWScript.Prover.Exporter
import Verifier.SAW.Translation.Coq
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>))


-- | Extract out the contents of the 'Right' of an 'Either', calling 'fail' if
-- the 'Either' is a 'Left'. The supplied 'String' describes the action (in
-- "ing" form, as in, "parsing") that was performed to create this 'Either'.
failOnLeft :: (MonadFail m, Show err) => String -> Either err a -> m a
failOnLeft action (Left err) = Fail.fail ("Error" ++ action ++ ": " ++ show err)
failOnLeft _ (Right a) = return a

-- | Extract out the contents of the 'Just' of a 'Maybe' wrapped in a
-- `MonadFail`, calling 'fail' on the given string if the `Maybe` is a
-- `Nothing`.
failOnNothing :: MonadFail m => String -> Maybe a -> m a
failOnNothing err_str Nothing = Fail.fail err_str
failOnNothing _ (Just a) = return a

getLLVMCFG :: ArchRepr arch -> SAW_CFG -> AnyCFG (LLVM arch)
getLLVMCFG _ (LLVM_CFG cfg) =
  -- FIXME: there should be an ArchRepr argument for LLVM_CFG to compare here!
  unsafeCoerce cfg
getLLVMCFG _ (JVM_CFG _) =
  error "getLLVMCFG: expected LLVM CFG, found JVM CFG!"

archReprWidth :: ArchRepr arch -> NatRepr (ArchWidth arch)
archReprWidth (X86Repr w) = w

llvmModuleArchRepr :: LLVMModule arch -> ArchRepr arch
llvmModuleArchRepr lm = llvmArch $ _transContext (lm ^. modTrans)

llvmModuleArchReprWidth :: LLVMModule arch -> NatRepr (ArchWidth arch)
llvmModuleArchReprWidth = archReprWidth . llvmModuleArchRepr

lookupModDefiningSym :: HeapsterEnv -> String -> Maybe (Some LLVMModule)
lookupModDefiningSym env nm =
  find (\(Some lm) -> Map.member (fromString nm) (cfgMap (lm ^. modTrans))) $
  heapsterEnvLLVMModules env

lookupModDeclaringSym :: HeapsterEnv -> String -> Maybe (Some LLVMModule)
lookupModDeclaringSym env nm =
  find (\(Some lm) -> 
         Map.member (fromString nm) (lm ^. modTrans.transContext.symbolMap)) $
  heapsterEnvLLVMModules env

lookupLLVMSymbolCFG :: BuiltinContext -> Options -> LLVMModule arch ->
                       String -> TopLevel (AnyCFG (LLVM arch))
lookupLLVMSymbolCFG bic opts lm nm =
  getLLVMCFG (llvmModuleArchRepr lm) <$>
  crucible_llvm_cfg bic opts (Some lm) nm

data ModuleAndCFG arch =
  ModuleAndCFG (LLVMModule arch) (AnyCFG (LLVM arch))

lookupLLVMSymbolModAndCFG :: BuiltinContext -> Options -> HeapsterEnv ->
                             String -> TopLevel (Maybe (Some ModuleAndCFG))
lookupLLVMSymbolModAndCFG bic opts henv nm =
  case lookupModDefiningSym henv nm of
    Just (Some lm) ->
      (Just . Some . ModuleAndCFG lm) <$> lookupLLVMSymbolCFG bic opts lm nm
    Nothing -> return Nothing


heapster_default_env :: PermEnv
heapster_default_env = PermEnv [] [] [] []

-- | Based on the function of the same name in Verifier.SAW.ParserUtils.
-- Unlike that function, this calls 'fail' instead of 'error'.
readModuleFromFile :: FilePath -> TopLevel (Un.Module, ModuleName)
readModuleFromFile path = do
  base <- liftIO getCurrentDirectory
  b <- liftIO $ BL.readFile path
  case Un.parseSAW base path b of
    (m@(Un.Module (Un.PosPair _ mnm) _ _),[]) -> pure (m, mnm)
    (_,errs) -> fail $ "Module parsing failed:\n" ++ show errs

-- | Parse the second given string as a term, the first given string being
-- used as the path for error reporting
parseTermFromString :: String -> String -> TopLevel Un.Term
parseTermFromString nm term_string = do
  let base = ""
      path = "<" ++ nm ++ ">"
  case Un.parseSAWTerm base path (BL.fromString term_string) of
    (term,[]) -> pure term
    (_,errs) -> fail $ "Term parsing failed:\n" ++ show errs

-- | Parse the second given string as a term, check that it has the given type,
-- and, if the parsed term is not already an identifier, add it as a
-- definition in the current module using the first given string. Returns
-- either the identifer of the new definition or the identifier parsed.
parseAndInsDef :: HeapsterEnv -> String -> Term -> String -> TopLevel Ident
parseAndInsDef henv nm term_tp term_string =
  do sc <- getSharedContext
     un_term <- parseTermFromString nm term_string
     let mnm = heapsterEnvSAWModule henv
     typed_term <- liftIO $ scTypeCheckCompleteError sc (Just mnm) un_term
     liftIO $ scCheckSubtype sc (Just mnm) typed_term term_tp
     case typedVal typed_term of
       STApp _ _ (FTermF (GlobalDef term_ident)) ->
         return term_ident
       term -> do
         let term_ident = mkSafeIdent mnm nm
         liftIO $ scModifyModule sc mnm $ \m ->
           insDef m $ Def { defIdent = term_ident,
                            defQualifier = NoQualifier,
                            defType = term_tp,
                            defBody = Just term }
         pure term_ident


heapster_init_env :: BuiltinContext -> Options -> String -> String ->
                     TopLevel HeapsterEnv
heapster_init_env _bic _opts mod_str llvm_filename =
  do llvm_mod <- llvm_load_module llvm_filename
     sc <- getSharedContext
     let saw_mod_name = mkModuleName [mod_str]
     mod_loaded <- liftIO $ scModuleIsLoaded sc saw_mod_name
     if mod_loaded then
       fail ("SAW module with name " ++ show mod_str ++ " already defined!")
       else return ()
     -- import Prelude by default
     preludeMod <- liftIO $ scFindModule sc preludeModuleName
     liftIO $ scLoadModule sc (insImport (const True) preludeMod $
                                 emptyModule saw_mod_name)
     perm_env_ref <- liftIO $ newIORef heapster_default_env
     return $ HeapsterEnv {
       heapsterEnvSAWModule = saw_mod_name,
       heapsterEnvPermEnvRef = perm_env_ref,
       heapsterEnvLLVMModules = [llvm_mod]
       }

heapster_init_env_from_file :: BuiltinContext -> Options -> String -> String ->
                               TopLevel HeapsterEnv
heapster_init_env_from_file _bic _opts mod_filename llvm_filename =
  do llvm_mod <- llvm_load_module llvm_filename
     sc <- getSharedContext
     (saw_mod, saw_mod_name) <- readModuleFromFile mod_filename
     liftIO $ tcInsertModule sc saw_mod
     perm_env_ref <- liftIO $ newIORef heapster_default_env
     return $ HeapsterEnv {
       heapsterEnvSAWModule = saw_mod_name,
       heapsterEnvPermEnvRef = perm_env_ref,
       heapsterEnvLLVMModules = [llvm_mod]
       }

heapster_init_env_for_files :: BuiltinContext -> Options -> String -> [String] ->
                               TopLevel HeapsterEnv
heapster_init_env_for_files _bic _opts mod_filename llvm_filenames =
  do llvm_mods <- mapM llvm_load_module llvm_filenames
     sc <- getSharedContext
     (saw_mod, saw_mod_name) <- readModuleFromFile mod_filename
     liftIO $ tcInsertModule sc saw_mod
     perm_env_ref <- liftIO $ newIORef heapster_default_env
     return $ HeapsterEnv {
       heapsterEnvSAWModule = saw_mod_name,
       heapsterEnvPermEnvRef = perm_env_ref,
       heapsterEnvLLVMModules = llvm_mods
       }

-- | Define a new opaque named permission with the given name, arguments, and
-- type, that translates to the given named SAW core definition
heapster_define_opaque_perm :: BuiltinContext -> Options -> HeapsterEnv ->
                               String -> String -> String -> String ->
                               TopLevel ()
heapster_define_opaque_perm _bic _opts henv nm args_str tp_str term_string =
  do env <- liftIO $ readIORef $ heapsterEnvPermEnvRef henv
     Some args <- parseCtxString "argument types" env args_str
     Some tp_perm <- parseTypeString "permission type" env tp_str
     sc <- getSharedContext
     term_tp <- liftIO $ translateCompleteType sc (emptyTypeTransInfo env)
                                                  (ValuePermRepr tp_perm)
     term_ident <- parseAndInsDef henv nm term_tp term_string
     let env' = permEnvAddOpaquePerm env nm args tp_perm term_ident
     liftIO $ writeIORef (heapsterEnvPermEnvRef henv) env'

-- | Define a new recursive named permission with the given name, arguments,
-- type, that translates to the given named SAW core definition.
heapster_define_recursive_perm :: BuiltinContext -> Options -> HeapsterEnv ->
                                  String -> String -> String -> [String] ->
                                  String -> String -> String ->
                                  TopLevel ()
heapster_define_recursive_perm _bic _opts henv
  nm args_str val_str p_strs trans_str fold_fun_str unfold_fun_str =
    do env <- liftIO $ readIORef $ heapsterEnvPermEnvRef henv
       Some args_ctx <- parseParsedCtxString "argument types" env args_str
       let args = parsedCtxCtx args_ctx
       Some val_perm <- parseTypeString "permission type" env val_str
       let rpn = NamedPermName nm val_perm args
       
       sc <- getSharedContext
       trans_tp <- liftIO $ 
         translateCompleteTypeInCtx sc (emptyTypeTransInfo env) args
           (nus (cruCtxProxies args) . const $ ValuePermRepr val_perm)
       trans_ident <- parseAndInsDef henv nm trans_tp trans_str
       
       p_perms <- forM p_strs $ \p_str ->
          parsePermInCtxString "disjunctive perm" env
                               [(nm, SomeNamedPermName rpn)]
                               args_ctx val_perm p_str
       
       let or_tp = foldr1 (mbMap2 ValPerm_Or) p_perms
           nm_tp = nus (cruCtxProxies args) (ValPerm_Named rpn . pExprVars)
           npnts = [(SomeNamedPermName rpn, trans_ident)]
       fold_fun_tp   <- liftIO $
          translateCompletePureFun sc (TypeTransInfo MNil npnts env) args
                                      (singletonValuePerms <$> or_tp) nm_tp
       unfold_fun_tp <- liftIO $
          translateCompletePureFun sc (TypeTransInfo MNil npnts env) args
                                      (singletonValuePerms <$> nm_tp) or_tp
       fold_ident   <- parseAndInsDef henv nm fold_fun_tp fold_fun_str
       unfold_ident <- parseAndInsDef henv nm unfold_fun_tp unfold_fun_str

       let env' = permEnvAddRecPerm env nm args val_perm p_perms
                                    trans_ident fold_ident unfold_ident
       liftIO $ writeIORef (heapsterEnvPermEnvRef henv) env'

-- | Define a new named permission with the given name, arguments, and type
-- that is equivalent to the given permission.
heapster_define_perm :: BuiltinContext -> Options -> HeapsterEnv ->
                        String -> String -> String -> String ->
                        TopLevel ()
heapster_define_perm _bic _opts henv nm args_str tp_str perm_string =
  do env <- liftIO $ readIORef $ heapsterEnvPermEnvRef henv
     Some args_ctx <- parseParsedCtxString "argument types" env args_str
     let args = parsedCtxCtx args_ctx
     Some tp_perm <- parseTypeString "permission type" env tp_str
     perm <- parsePermInCtxString "disjunctive perm" env []
                                   args_ctx tp_perm perm_string
     let env' = permEnvAddDefinedPerm env nm args tp_perm perm
     liftIO $ writeIORef (heapsterEnvPermEnvRef henv) env'

-- | Add a hint to the Heapster type-checker that Crucible block number @block@ in
-- function @fun@ should have permissions @perms@ on its inputs
heapster_block_entry_hint :: BuiltinContext -> Options -> HeapsterEnv ->
                             String -> Int -> String -> String -> String ->
                             TopLevel ()
heapster_block_entry_hint bic opts henv nm blk top_args_str ghosts_str perms_str =
  do env <- liftIO $ readIORef $ heapsterEnvPermEnvRef henv
     Some top_args_p <-
       parseParsedCtxString "top-level argument context" env top_args_str
     Some ghosts_p <-
       parseParsedCtxString "ghost argument context" env ghosts_str
     Some (ModuleAndCFG _ (AnyCFG cfg)) <-
       failOnNothing ("Could not find symbol definition: " ++ nm) =<<
         lookupLLVMSymbolModAndCFG bic opts henv nm
     let top_args = parsedCtxCtx top_args_p
         ghosts = parsedCtxCtx ghosts_p
         h = cfgHandle cfg
         blocks = fmapFC blockInputs $ cfgBlockMap cfg
     Some blockIx <-
       failOnNothing ("Block ID " ++ show blk ++ " not found in function " ++ nm)
                     (Ctx.intIndex blk (Ctx.size blocks))
     let block_ID = BlockID blockIx
         block_args = blocks Ctx.! blockIx
     perms <- parsePermsString "block entry permissions" env
               (appendParsedCtx
                (appendParsedCtx top_args_p
                 (mkArgsParsedCtx $ mkCruCtx block_args)) ghosts_p)
               perms_str
     let env' = permEnvAddHint env $ Hint_BlockEntry $
                 BlockEntryHint h blocks block_ID top_args ghosts perms
     liftIO $ writeIORef (heapsterEnvPermEnvRef henv) env'


-- | Assume that the given named function has the supplied type and translates
-- to a SAW core definition given by name
heapster_assume_fun :: BuiltinContext -> Options -> HeapsterEnv ->
                       String -> String -> String -> TopLevel ()
heapster_assume_fun _bic _opts henv nm perms_string term_string =
  do Some lm <- failOnNothing ("Could not find symbol: " ++ nm)
                              (lookupModDeclaringSym henv nm)
     sc <- getSharedContext
     let w = llvmModuleArchReprWidth lm
     leq_proof <- case decideLeq (knownNat @1) w of
       Left pf -> return pf
       Right _ -> fail "LLVM arch width is 0!"
     env <- liftIO $ readIORef $ heapsterEnvPermEnvRef henv
     LLVMHandleInfo _ h <-
       failOnNothing ("Unreachable: could not find symbol: " ++ nm) $
         lm ^. modTrans.transContext.symbolMap.at (L.Symbol nm)
     let args = mkCruCtx $ handleArgTypes h
         ret = handleReturnType h
     withKnownNat w $ withLeqProof leq_proof $ do
        SomeFunPerm fun_perm <-
          parseFunPermString "permissions" env args ret perms_string
        perm_env <- liftIO $ readIORef (heapsterEnvPermEnvRef henv)
        fun_typ <- liftIO $
          translateCompleteFunPerm sc (emptyTypeTransInfo perm_env)
                                      fun_perm
        term_ident <- parseAndInsDef henv nm fun_typ term_string
        let env' = permEnvAddGlobalSymFun env
                                          (GlobalSymbol $ fromString nm)
                                          w
                                          fun_perm
                                          (globalOpenTerm term_ident)
        liftIO $ writeIORef (heapsterEnvPermEnvRef henv) env'


heapster_typecheck_mut_funs :: BuiltinContext -> Options -> HeapsterEnv ->
                               [(String, String)] -> TopLevel ()
heapster_typecheck_mut_funs bic opts henv fn_names_and_perms =
  do let fst_nm = fst $ head fn_names_and_perms
     Some lm <- failOnNothing ("Could not find symbol definition: " ++ fst_nm)
                              (lookupModDefiningSym henv fst_nm)
     let w = llvmModuleArchReprWidth lm
     env <- liftIO $ readIORef $ heapsterEnvPermEnvRef henv
     some_cfgs_and_perms <- forM fn_names_and_perms $ \(nm,perms_string) ->
       lookupLLVMSymbolCFG bic opts lm nm >>= \(AnyCFG cfg) ->
           do let args = mkCruCtx $ handleArgTypes $ cfgHandle cfg
              let ret = handleReturnType $ cfgHandle cfg
              SomeFunPerm fun_perm <-
                parseFunPermString "permissions" env args ret perms_string
              return $ SomeCFGAndPerm (GlobalSymbol $ fromString nm)
                                      cfg fun_perm
     sc <- getSharedContext
     let saw_modname = heapsterEnvSAWModule henv
     leq_proof <- case decideLeq (knownNat @1) w of
       Left pf -> return pf
       Right _ -> fail "LLVM arch width is 0!"
     env' <- liftIO $ withKnownNat w $ withLeqProof leq_proof $
       tcTranslateAddCFGs sc saw_modname w env some_cfgs_and_perms
     liftIO $ writeIORef (heapsterEnvPermEnvRef henv) env'


heapster_typecheck_fun :: BuiltinContext -> Options -> HeapsterEnv ->
                          String -> String -> TopLevel ()
heapster_typecheck_fun bic opts henv fn_name perms_string =
  heapster_typecheck_mut_funs bic opts henv [(fn_name, perms_string)]

heapster_print_fun_trans :: BuiltinContext -> Options -> HeapsterEnv ->
                            String -> TopLevel ()
heapster_print_fun_trans _bic _opts henv fn_name =
  do pp_opts <- getTopLevelPPOpts
     sc <- getSharedContext
     let saw_modname = heapsterEnvSAWModule henv
     fun_term <-
       fmap (fromJust . defBody) $
       liftIO $ scRequireDef sc $ mkSafeIdent saw_modname fn_name
     liftIO $ putStrLn $ scPrettyTerm pp_opts fun_term

heapster_export_coq :: BuiltinContext -> Options -> HeapsterEnv ->
                       String -> TopLevel ()
heapster_export_coq _bic _opts henv filename =
  do let coq_trans_conf = coqTranslationConfiguration [] []
     sc <- getSharedContext
     saw_mod <- liftIO $ scFindModule sc $ heapsterEnvSAWModule henv
     let coq_doc =
           vcat [preamblePlus coq_trans_conf
                 (string "From CryptolToCoq Require Import SAWCorePrelude."),
                 translateSAWModule coq_trans_conf saw_mod]
     liftIO $ writeFile filename (show coq_doc)

heapster_parse_test :: BuiltinContext -> Options -> Some LLVMModule ->
                       String -> String ->  TopLevel ()
heapster_parse_test bic opts some_lm@(Some lm) fn_name perms_string =
  do let env = heapster_default_env -- FIXME: env should be an argument
     let arch = llvmArch $ _transContext (lm ^. modTrans)
     AnyCFG cfg <- getLLVMCFG arch <$> crucible_llvm_cfg bic opts some_lm fn_name
     let args = mkCruCtx $ handleArgTypes $ cfgHandle cfg
     let ret = handleReturnType $ cfgHandle cfg
     SomeFunPerm fun_perm <- parseFunPermString "permissions" env args
                                                ret perms_string
     liftIO $ putStrLn $ permPrettyString emptyPPInfo fun_perm

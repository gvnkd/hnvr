{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Minimal Haskell binding to ONNX Runtime C API.
--
-- We deliberately /do not/ depend on @hs-onnxruntime-capi@ from
-- Hackage — it is stale and won't build on GHC 9.12. The heavy lifting
-- (dlopen + vtable resolution) lives in "Hnvr.Cv.OnnxRuntime.Internal";
-- this module is the ergonomic surface the analyzer consumes.
--
-- The shared library is located via @HNVR_ONNXRUNTIME_LIB@ (absolute
-- path to @libonnxruntime.so@), falling back to the linker default
-- search for @libonnxruntime.so@. The NixOS module and devenv wire the
-- env var to the nixpkgs @onnxruntime@ package output.
--
-- EP selection: pass the priority list from @HNVR_EXEC_PROVIDERS@
-- (parsed by the caller) — the first provider whose session creation
-- succeeds wins. CPU is always available as the last resort.
--
-- See @design_docs/04-cv-pipeline.md@ ("ONNX Runtime Haskell binding").
module Hnvr.Cv.OnnxRuntime
  ( ExecutionProvider (..),
    Tensor (..),
    Session,
    sessionActiveEp,
    sessionInputName,
    sessionOutputName,
    sessionInputShape,
    sessionOutputShape,
    versionString,
    withSession,
    infer,
    OrtError (..),
  )
where

import Control.Exception (bracket, onException, throwIO, try)
import Control.Monad (when)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Foreign as TF
import qualified Data.Vector.Storable as VS
import Foreign
import Foreign.C.String (CString, newCString, peekCString)
import Foreign.C.Types (CInt (..), CSize (..))
import Hnvr.Cv.OnnxRuntime.Internal
import System.Environment (lookupEnv)
import System.IO (hFlush, hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)

-- | Execution provider, in priority order per host.
data ExecutionProvider = CPU | CUDA | TensorRT
  deriving stock (Eq, Show)

-- | A float32 tensor in row-major order.
data Tensor = Tensor
  { tensorShape :: [Int64],
    tensorData :: VS.Vector Float
  }
  deriving stock (Eq, Show)

-- | An inference session: ORT handle + cached IO names + the EP that
-- actually initialized. One per analyzer worker; 'infer' is safe to
-- call from any thread but sessions are not shared across workers.
data Session = Session
  { sessApi :: Api,
    sessEnv :: Ptr OrtEnv,
    sessOpts :: Ptr OrtSessionOptions,
    sessPtr :: Ptr OrtSession,
    sessMemInfo :: Ptr OrtMemoryInfo,
    sessInputNameC :: CString,
    sessOutputNameC :: CString,
    sessionInputName :: Text,
    sessionOutputName :: Text,
    sessionInputShape :: [Int64],
    sessionOutputShape :: [Int64],
    sessionActiveEp :: ExecutionProvider
  }

-- Process-global state: the resolved vtable + the single OrtEnv (ORT
-- docs: one env per process; sessions are the per-worker unit).
{-# NOINLINE globalState #-}
globalState :: IORef (Maybe (Api, Ptr OrtEnv))
globalState = unsafePerformIO (newIORef Nothing)

ensureGlobal :: IO (Api, Ptr OrtEnv)
ensureGlobal = do
  cached <- readIORef globalState
  case cached of
    Just ae -> pure ae
    Nothing -> do
      libPath <- fromMaybe "libonnxruntime.so" <$> lookupEnv "HNVR_ONNXRUNTIME_LIB"
      api <- loadApi libPath
      env <- alloca $ \out -> do
        checked api "CreateEnv" $
          TF.withCString "hnvr" (\logid -> apiCreateEnv api ortLoggingLevelWarning logid out)
        peek out
      writeIORef globalState (Just (api, env))
      pure (api, env)

ortLoggingLevelWarning :: CInt
ortLoggingLevelWarning = 2

-- OrtAllocatorType / OrtMemType for CPU input tensors.
-- OrtDeviceAllocator matches ORT's own MemoryInfo::CreateCpu default
-- (the arena allocator is for ORT-owned allocations, not user memory).
ortDeviceAllocator, ortMemTypeDefault :: CInt
ortDeviceAllocator = 0
ortMemTypeDefault = 0

onnxTensorElementDataTypeFloat :: CInt
onnxTensorElementDataTypeFloat = 1

-- | ONNX Runtime library version, e.g. @"1.24.4"@.
versionString :: IO String
versionString = do
  (api, _) <- ensureGlobal
  apiVersionString api

-- | Create a session for @modelPath@, trying each EP in order. The
-- first provider whose @CreateSession@ succeeds wins; failures are
-- collected and reported if every EP fails. Bracketed: session,
-- options, and memory info are released on exit (the process-global
-- env is not).
withSession :: Text -> [ExecutionProvider] -> (Session -> IO r) -> IO r
withSession modelPath eps k = do
  (api, env) <- ensureGlobal
  (opts, memInfo, sess, ep) <- createWithFallback api env eps
  debugLog ("withSession: created session " <> showPtr sess <> " ep=" <> show ep)
  bracket (mkSession api env opts memInfo sess ep) teardown k
  where
    teardown sess = do
      debugLog ("withSession: releasing session " <> showPtr (sessPtr sess))
      let api = sessApi sess
      free (sessInputNameC sess)
      free (sessOutputNameC sess)
      apiReleaseSession api (sessPtr sess)
      apiReleaseMemoryInfo api (sessMemInfo sess)
      apiReleaseSessionOptions api (sessOpts sess)

    mkSession api env opts memInfo ptr ep = do
      inC <- getNameCString api ptr True
      outC <- getNameCString api ptr False
      inT <- T.pack <$> peekCString inC
      outT <- T.pack <$> peekCString outC
      inShape <- getIoShape api ptr True
      outShape <- getIoShape api ptr False
      pure
        Session
          { sessApi = api,
            sessEnv = env,
            sessOpts = opts,
            sessPtr = ptr,
            sessMemInfo = memInfo,
            sessInputNameC = inC,
            sessOutputNameC = outC,
            sessionInputName = inT,
            sessionOutputName = outT,
            sessionInputShape = inShape,
            sessionOutputShape = outShape,
            sessionActiveEp = ep
          }

    -- SessionGetInput/OutputTypeInfo → Cast → dims. The returned
    -- OrtTypeInfo is caller-released; the cast result is owned by it
    -- ("Do not free this value" per onnxruntime_c_api.h), so dims are
    -- read while the TypeInfo is alive and only it is released.
    getIoShape api ptr isInput = do
      ti <- alloca $ \out -> do
        checked api "SessionGetTypeInfo" $ getTypeInfo api ptr 0 out
        peek out
      flip onException (apiReleaseTypeInfo api ti) $ do
        info <- alloca $ \out -> do
          checked api "CastTypeInfoToTensorInfo" $ apiCastTypeInfoToTensorInfo api ti out
          peek out
        shape <- dimsOfInfo api info
        apiReleaseTypeInfo api ti
        pure shape
      where
        getTypeInfo =
          if isInput
            then apiSessionGetInputTypeInfo
            else apiSessionGetOutputTypeInfo

    -- SessionGetInputName/OutputName allocate via the default
    -- allocator; copy to a Haskell-owned CString and free the ORT one.
    getNameCString api ptr isInput = alloca $ \allocOut -> alloca $ \nameOut -> do
      checked api "GetAllocatorWithDefaultOptions" $ apiGetAllocatorWithDefaultOptions api allocOut
      alloc <- peek allocOut
      let getName = if isInput then apiSessionGetInputName else apiSessionGetOutputName
      checked api "SessionGetName" $ getName api ptr 0 alloc nameOut
      ortName <- peek nameOut
      owned <- newCString =<< peekCString ortName
      checked api "AllocatorFree" $ apiAllocatorFree api alloc (castPtr ortName)
      pure owned

    createWithFallback _ _ [] =
      throwIO (OrtError "withSession" "no execution providers configured")
    createWithFallback api env eps0 = go [] eps0
      where
        go errs [] =
          throwIO (OrtError "withSession" (T.intercalate "; " (reverse errs)))
        go errs (ep : rest) = do
          attempt <- try (createOn api env ep)
          case attempt of
            Right ok -> pure ok
            Left (OrtError _ msg) ->
              go ((T.pack (show ep) <> ": " <> msg) : errs) rest

    createOn api env ep = do
      opts <- alloca $ \out -> do
        checked api "CreateSessionOptions" $ apiCreateSessionOptions api out
        peek out
      flip onException (apiReleaseSessionOptions api opts) $ do
        -- Multi-session hardening (Aug 12 2026 SIGSEGV hunt): one
        -- analyzer per camera means N concurrent sessions per process.
        -- ORT's default intra-op pool = all cores PER SESSION (3 cams
        -- × 32 threads here) and its cross-session memory-pattern
        -- arena is documented as unsafe for many concurrent sessions.
        -- Cap intra-op to 4 (5 fps × small model needs little per
        -- session) and turn off both arenas.
        checked api "SetIntraOpNumThreads" $ apiSetIntraOpNumThreads api opts 4
        checked api "DisableMemPattern" $ apiDisableMemPattern api opts
        checked api "DisableCpuMemArena" $ apiDisableCpuMemArena api opts
        appendEp api opts ep
        memInfo <- alloca $ \out -> do
          checked api "CreateCpuMemoryInfo" $
            apiCreateCpuMemoryInfo api ortDeviceAllocator ortMemTypeDefault out
          peek out
        sess <-
          TF.withCString modelPath $ \pathC -> alloca $ \out -> do
            checked api "CreateSession" $ apiCreateSession api env pathC opts out
            peek out
        pure (opts, memInfo, sess, ep)

    appendEp _ _ CPU = pure ()
    appendEp api opts CUDA =
      bracket
        ( alloca $ \out -> do
            checked api "CreateCUDAProviderOptions" $ apiCreateCUDAProviderOptions api out
            peek out
        )
        (apiReleaseCUDAProviderOptions api)
        ( checked api "SessionOptionsAppendExecutionProvider_CUDA_V2"
            . apiAppendCUDAV2 api opts
        )
    appendEp api opts TensorRT =
      bracket
        ( alloca $ \out -> do
            checked api "CreateTensorRTProviderOptions" $ apiCreateTensorRTProviderOptions api out
            peek out
        )
        (apiReleaseTensorRTProviderOptions api)
        ( checked api "SessionOptionsAppendExecutionProvider_TensorRT_V2"
            . apiAppendTensorRTV2 api opts
        )

-- | Run one inference. The input tensor is wrapped in-place (no copy);
-- the output is copied out into a fresh 'Tensor'.
--
-- LIVENESS: 'VS.unsafeWith' must wrap the ENTIRE create+Run — the
-- vector is only guaranteed live during its callback. Hoisting the
-- tensor creation into a bracket acquire (as done before Aug 12 2026)
-- let GHC collect the frame memory while ORT was still reading it —
-- silent native SIGSEGV under multi-camera load.
infer :: Session -> Tensor -> IO Tensor
infer sess (Tensor shape vec) = do
  let api = sessApi sess
      elemCount = VS.length vec
  VS.unsafeWith vec $ \dataPtr ->
    withArrayLen shape $ \shapeLen shapePtr -> do
      debugLog ("infer: session " <> showPtr (sessPtr sess) <> " input " <> show dataPtr)
      bracket
        ( alloca $ \out -> do
            checked api "CreateTensorWithDataAsOrtValue" $
              apiCreateTensorWithDataAsOrtValue
                api
                (sessMemInfo sess)
                dataPtr
                (fromIntegral (elemCount * sizeOf (0 :: Float)))
                shapePtr
                (fromIntegral shapeLen)
                onnxTensorElementDataTypeFloat
                out
            peek out
        )
        (apiReleaseValue api)
        $ \inputValue -> withArray [sessInputNameC sess] $ \inNames ->
          withArray [sessOutputNameC sess] $ \outNames -> withArray [inputValue] $ \inVals ->
            alloca $ \outValOut -> do
              -- ORT contract: output slots must be NULL so ORT
              -- allocates the output OrtValues itself. An
              -- uninitialized alloca slot can hold non-null stack
              -- garbage, which ORT then treats as a caller-provided
              -- OrtValue to copy-construct from → SIGSEGV deep inside
              -- InferenceSession::Run (Aug 12 2026 leader crash hunt;
              -- passes in tests because fresh stacks read as zero,
              -- crashes in the leader's reused stack).
              poke outValOut nullPtr
              checked api "Run" $
                apiRun api (sessPtr sess) nullPtr inNames inVals 1 outNames 1 outValOut
              outVal <- peek outValOut
              bracket (pure outVal) (apiReleaseValue api) $ \_ -> do
                outShape <- tensorShapeOf api outVal
                outDataPtr <- alloca $ \dataOut -> do
                  checked api "GetTensorMutableData" $ apiGetTensorMutableData api outVal dataOut
                  peek dataOut
                let n = fromIntegral (product outShape)
                outVec <- VS.generateM n (peekElemOff outDataPtr)
                pure (Tensor outShape outVec)

-- | stderr trace behind @HNVR_ORT_DEBUG=1@ — SIGSEGV forensics (Aug
-- 12 2026). Cheap string check; off in production.
debugLog :: String -> IO ()
debugLog msg = do
  on <- (== Just "1") <$> lookupEnv "HNVR_ORT_DEBUG"
  when on $ hPutStrLn stderr ("[ort] " <> msg) >> hFlush stderr

showPtr :: Ptr a -> String
showPtr = show

-- | Shape of a live OrtValue tensor.
tensorShapeOf :: Api -> Ptr OrtValue -> IO [Int64]
tensorShapeOf api val =
  bracket
    ( alloca $ \out -> do
        checked api "GetTensorTypeAndShape" $ apiGetTensorTypeAndShape api val out
        peek out
    )
    (apiReleaseTensorTypeAndShapeInfo api)
    (dimsOfInfo api)

-- | Dimensions of a tensor type-and-shape descriptor.
dimsOfInfo :: Api -> Ptr OrtTensorTypeAndShapeInfo -> IO [Int64]
dimsOfInfo api info = do
  ndim <- alloca $ \ndimOut -> do
    checked api "GetDimensionsCount" $ apiGetDimensionsCount api info ndimOut
    fromIntegral <$> peek ndimOut
  allocaArray ndim $ \dims -> do
    checked api "GetDimensions" $ apiGetDimensions api info dims (fromIntegral ndim)
    peekArray ndim dims

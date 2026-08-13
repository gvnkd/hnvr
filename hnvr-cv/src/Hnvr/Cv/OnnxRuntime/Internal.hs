{-# LANGUAGE DerivingStrategies #-}

-- | Low-level ONNX Runtime C API binding.
--
-- The C API is a single vtable struct obtained via
-- @OrtGetApiBase()->GetApi(ORT_API_VERSION)@. We dlopen
-- @libonnxruntime.so@ once per process and wrap each needed function
-- pointer with @foreign import ccall "dynamic"@.
--
-- Vtable indices below are generated from @onnxruntime_c_api.h@ of
-- onnxruntime 1.27.1 (@ORT_API_VERSION 27@, the flake-pinned nixpkgs
-- version — the channel's 1.24.4 was a red herring, see pitfall #98).
-- Verified: every index we use is identical between 1.24.4 and
-- 1.27.1 (ORT's ABI is append-only). If the nixpkgs onnxruntime
-- version changes, regenerate the index table before touching
-- anything else — stale indices are silent memory corruption.
module Hnvr.Cv.OnnxRuntime.Internal
  ( -- * Opaque C types
    OrtApiBase,
    OrtApi,
    OrtEnv,
    OrtSession,
    OrtSessionOptions,
    OrtValue,
    OrtMemoryInfo,
    OrtAllocator,
    OrtStatus,
    OrtTensorTypeAndShapeInfo,
    OrtTypeInfo,
    OrtCUDAProviderOptionsV2,
    OrtTensorRTProviderOptionsV2,

    -- * Library loading
    Api (..),
    loadApi,
    ortApiVersion,

    -- * Status handling
    OrtError (..),
    checked,
  )
where

import Control.Exception (Exception, throwIO)
import Control.Monad (when, (<=<))
import Data.Text (Text)
import qualified Data.Text as T
import Foreign
import Foreign.C.String (CString, peekCString)
import Foreign.C.Types (CInt (..), CSize (..))
import System.Posix.DynamicLinker (RTLDFlags (RTLD_GLOBAL, RTLD_NOW), dlopen, dlsym)

-- Opaque ORT handles.
data OrtApiBase

data OrtApi

data OrtEnv

data OrtSession

data OrtSessionOptions

data OrtValue

data OrtMemoryInfo

data OrtAllocator

data OrtStatus

data OrtTensorTypeAndShapeInfo

data OrtTypeInfo

data OrtCUDAProviderOptionsV2

data OrtTensorRTProviderOptionsV2

-- | Must match the header the indices were generated from (ORT's ABI
-- is append-only, so older API versions keep working at runtime — but
-- the index table is only guaranteed for the pinned header).
ortApiVersion :: Word32
ortApiVersion = 27

-- | ORT call failed; payload is the call site + ORT's error message.
data OrtError = OrtError Text Text
  deriving stock (Show)

instance Exception OrtError

-- Vtable indices (onnxruntime 1.27.1, ORT_API_VERSION 27).
idxGetErrorMessage,
  idxCreateEnv,
  idxCreateSession,
  idxRun,
  idxCreateSessionOptions,
  idxDisableMemPattern,
  idxDisableCpuMemArena,
  idxSetSessionLogSeverityLevel,
  idxSetIntraOpNumThreads,
  idxSessionGetInputCount,
  idxSessionGetOutputCount,
  idxSessionGetInputName,
  idxSessionGetOutputName,
  idxSessionGetInputTypeInfo,
  idxSessionGetOutputTypeInfo,
  idxCastTypeInfoToTensorInfo,
  idxCreateTensorWithDataAsOrtValue,
  idxGetTensorMutableData,
  idxGetDimensionsCount,
  idxGetDimensions,
  idxGetTensorTypeAndShape,
  idxCreateCpuMemoryInfo,
  idxAllocatorFree,
  idxGetAllocatorWithDefaultOptions,
  idxSessionOptionsAppendExecutionProviderTensorRTV2,
  idxCreateTensorRTProviderOptions,
  idxUpdateTensorRTProviderOptions,
  idxReleaseTensorRTProviderOptions,
  idxSessionOptionsAppendExecutionProviderCUDAV2,
  idxCreateCUDAProviderOptions,
  idxReleaseCUDAProviderOptions,
  idxReleaseEnv,
  idxReleaseStatus,
  idxReleaseSession,
  idxReleaseSessionOptions,
  idxReleaseValue,
  idxReleaseMemoryInfo,
  idxReleaseTensorTypeAndShapeInfo,
  idxReleaseTypeInfo ::
    Int
idxGetErrorMessage = 2
idxCreateEnv = 3
idxCreateSession = 7
idxRun = 9
idxCreateSessionOptions = 10
idxDisableMemPattern = 17
idxDisableCpuMemArena = 19
idxSetSessionLogSeverityLevel = 22
idxSetIntraOpNumThreads = 24
idxSessionGetInputCount = 30
idxSessionGetOutputCount = 31
idxSessionGetInputName = 36
idxSessionGetOutputName = 37
idxSessionGetInputTypeInfo = 33
idxSessionGetOutputTypeInfo = 34
idxCastTypeInfoToTensorInfo = 55
idxCreateTensorWithDataAsOrtValue = 49
idxGetTensorMutableData = 51
idxGetDimensionsCount = 61
idxGetDimensions = 62
idxGetTensorTypeAndShape = 65
idxCreateCpuMemoryInfo = 69
idxAllocatorFree = 76
idxGetAllocatorWithDefaultOptions = 78
idxSessionOptionsAppendExecutionProviderTensorRTV2 = 170
idxCreateTensorRTProviderOptions = 171
idxUpdateTensorRTProviderOptions = 172
idxReleaseTensorRTProviderOptions = 174
idxSessionOptionsAppendExecutionProviderCUDAV2 = 204
idxCreateCUDAProviderOptions = 205
idxReleaseCUDAProviderOptions = 208
idxReleaseEnv = 92
idxReleaseStatus = 93
idxReleaseMemoryInfo = 94
idxReleaseSession = 95
idxReleaseValue = 96
idxReleaseTensorTypeAndShapeInfo = 99
idxReleaseSessionOptions = 100
idxReleaseTypeInfo = 98

-- Dynamic wrappers (one per distinct C signature).
foreign import ccall "dynamic" mkGetApiBase :: FunPtr (IO (Ptr OrtApiBase)) -> IO (Ptr OrtApiBase)

foreign import ccall "dynamic" mkGetApi :: FunPtr (Word32 -> IO (Ptr OrtApi)) -> Word32 -> IO (Ptr OrtApi)

foreign import ccall "dynamic" mkGetVersionString :: FunPtr (IO CString) -> IO CString

foreign import ccall "dynamic" mkGetErrorMessage :: FunPtr (Ptr OrtStatus -> IO CString) -> Ptr OrtStatus -> IO CString

foreign import ccall "dynamic" mkCreateEnv :: FunPtr (CInt -> CString -> Ptr (Ptr OrtEnv) -> IO (Ptr OrtStatus)) -> CInt -> CString -> Ptr (Ptr OrtEnv) -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkCreateSession :: FunPtr (Ptr OrtEnv -> CString -> Ptr OrtSessionOptions -> Ptr (Ptr OrtSession) -> IO (Ptr OrtStatus)) -> Ptr OrtEnv -> CString -> Ptr OrtSessionOptions -> Ptr (Ptr OrtSession) -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkRun :: FunPtr (Ptr OrtSession -> Ptr () -> Ptr CString -> Ptr (Ptr OrtValue) -> CSize -> Ptr CString -> CSize -> Ptr (Ptr OrtValue) -> IO (Ptr OrtStatus)) -> Ptr OrtSession -> Ptr () -> Ptr CString -> Ptr (Ptr OrtValue) -> CSize -> Ptr CString -> CSize -> Ptr (Ptr OrtValue) -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkCreateSessionOptions :: FunPtr (Ptr (Ptr OrtSessionOptions) -> IO (Ptr OrtStatus)) -> Ptr (Ptr OrtSessionOptions) -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkSessionOptInt :: FunPtr (Ptr OrtSessionOptions -> CInt -> IO (Ptr OrtStatus)) -> Ptr OrtSessionOptions -> CInt -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkSessionOptVoid :: FunPtr (Ptr OrtSessionOptions -> IO (Ptr OrtStatus)) -> Ptr OrtSessionOptions -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkSessionGetCount :: FunPtr (Ptr OrtSession -> Ptr CSize -> IO (Ptr OrtStatus)) -> Ptr OrtSession -> Ptr CSize -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkSessionGetName :: FunPtr (Ptr OrtSession -> CSize -> Ptr OrtAllocator -> Ptr CString -> IO (Ptr OrtStatus)) -> Ptr OrtSession -> CSize -> Ptr OrtAllocator -> Ptr CString -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkSessionGetTypeInfo :: FunPtr (Ptr OrtSession -> CSize -> Ptr (Ptr OrtTypeInfo) -> IO (Ptr OrtStatus)) -> Ptr OrtSession -> CSize -> Ptr (Ptr OrtTypeInfo) -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkCastTypeInfoToTensorInfo :: FunPtr (Ptr OrtTypeInfo -> Ptr (Ptr OrtTensorTypeAndShapeInfo) -> IO (Ptr OrtStatus)) -> Ptr OrtTypeInfo -> Ptr (Ptr OrtTensorTypeAndShapeInfo) -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkCreateTensorWithDataAsOrtValue :: FunPtr (Ptr OrtMemoryInfo -> Ptr Float -> CSize -> Ptr Int64 -> CSize -> CInt -> Ptr (Ptr OrtValue) -> IO (Ptr OrtStatus)) -> Ptr OrtMemoryInfo -> Ptr Float -> CSize -> Ptr Int64 -> CSize -> CInt -> Ptr (Ptr OrtValue) -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkGetTensorMutableData :: FunPtr (Ptr OrtValue -> Ptr (Ptr Float) -> IO (Ptr OrtStatus)) -> Ptr OrtValue -> Ptr (Ptr Float) -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkGetTensorTypeAndShape :: FunPtr (Ptr OrtValue -> Ptr (Ptr OrtTensorTypeAndShapeInfo) -> IO (Ptr OrtStatus)) -> Ptr OrtValue -> Ptr (Ptr OrtTensorTypeAndShapeInfo) -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkGetDimensionsCount :: FunPtr (Ptr OrtTensorTypeAndShapeInfo -> Ptr CSize -> IO (Ptr OrtStatus)) -> Ptr OrtTensorTypeAndShapeInfo -> Ptr CSize -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkGetDimensions :: FunPtr (Ptr OrtTensorTypeAndShapeInfo -> Ptr Int64 -> CSize -> IO (Ptr OrtStatus)) -> Ptr OrtTensorTypeAndShapeInfo -> Ptr Int64 -> CSize -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkCreateCpuMemoryInfo :: FunPtr (CInt -> CInt -> Ptr (Ptr OrtMemoryInfo) -> IO (Ptr OrtStatus)) -> CInt -> CInt -> Ptr (Ptr OrtMemoryInfo) -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkAllocatorFree :: FunPtr (Ptr OrtAllocator -> Ptr () -> IO (Ptr OrtStatus)) -> Ptr OrtAllocator -> Ptr () -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkGetAllocatorWithDefaultOptions :: FunPtr (Ptr (Ptr OrtAllocator) -> IO (Ptr OrtStatus)) -> Ptr (Ptr OrtAllocator) -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkCreateCUDAProviderOptions :: FunPtr (Ptr (Ptr OrtCUDAProviderOptionsV2) -> IO (Ptr OrtStatus)) -> Ptr (Ptr OrtCUDAProviderOptionsV2) -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkAppendCUDAV2 :: FunPtr (Ptr OrtSessionOptions -> Ptr OrtCUDAProviderOptionsV2 -> IO (Ptr OrtStatus)) -> Ptr OrtSessionOptions -> Ptr OrtCUDAProviderOptionsV2 -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkCreateTensorRTProviderOptions :: FunPtr (Ptr (Ptr OrtTensorRTProviderOptionsV2) -> IO (Ptr OrtStatus)) -> Ptr (Ptr OrtTensorRTProviderOptionsV2) -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkUpdateTensorRTProviderOptions :: FunPtr (Ptr OrtTensorRTProviderOptionsV2 -> Ptr CString -> Ptr CString -> CSize -> IO (Ptr OrtStatus)) -> Ptr OrtTensorRTProviderOptionsV2 -> Ptr CString -> Ptr CString -> CSize -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkAppendTensorRTV2 :: FunPtr (Ptr OrtSessionOptions -> Ptr OrtTensorRTProviderOptionsV2 -> IO (Ptr OrtStatus)) -> Ptr OrtSessionOptions -> Ptr OrtTensorRTProviderOptionsV2 -> IO (Ptr OrtStatus)

foreign import ccall "dynamic" mkRelease :: FunPtr (Ptr a -> IO ()) -> Ptr a -> IO ()

-- | The vtable resolved into callable Haskell functions. Load once per
-- process via 'loadApi'; share across sessions.
data Api = Api
  { apiVersionString :: IO String,
    apiGetErrorMessage :: Ptr OrtStatus -> IO String,
    apiCreateEnv :: CInt -> CString -> Ptr (Ptr OrtEnv) -> IO (Ptr OrtStatus),
    apiCreateSession :: Ptr OrtEnv -> CString -> Ptr OrtSessionOptions -> Ptr (Ptr OrtSession) -> IO (Ptr OrtStatus),
    apiRun :: Ptr OrtSession -> Ptr () -> Ptr CString -> Ptr (Ptr OrtValue) -> CSize -> Ptr CString -> CSize -> Ptr (Ptr OrtValue) -> IO (Ptr OrtStatus),
    apiCreateSessionOptions :: Ptr (Ptr OrtSessionOptions) -> IO (Ptr OrtStatus),
    apiSetSessionLogSeverityLevel :: Ptr OrtSessionOptions -> CInt -> IO (Ptr OrtStatus),
    apiSetIntraOpNumThreads :: Ptr OrtSessionOptions -> CInt -> IO (Ptr OrtStatus),
    apiDisableMemPattern :: Ptr OrtSessionOptions -> IO (Ptr OrtStatus),
    apiDisableCpuMemArena :: Ptr OrtSessionOptions -> IO (Ptr OrtStatus),
    apiSessionGetInputCount :: Ptr OrtSession -> Ptr CSize -> IO (Ptr OrtStatus),
    apiSessionGetOutputCount :: Ptr OrtSession -> Ptr CSize -> IO (Ptr OrtStatus),
    apiSessionGetInputName :: Ptr OrtSession -> CSize -> Ptr OrtAllocator -> Ptr CString -> IO (Ptr OrtStatus),
    apiSessionGetOutputName :: Ptr OrtSession -> CSize -> Ptr OrtAllocator -> Ptr CString -> IO (Ptr OrtStatus),
    apiSessionGetInputTypeInfo :: Ptr OrtSession -> CSize -> Ptr (Ptr OrtTypeInfo) -> IO (Ptr OrtStatus),
    apiSessionGetOutputTypeInfo :: Ptr OrtSession -> CSize -> Ptr (Ptr OrtTypeInfo) -> IO (Ptr OrtStatus),
    apiCastTypeInfoToTensorInfo :: Ptr OrtTypeInfo -> Ptr (Ptr OrtTensorTypeAndShapeInfo) -> IO (Ptr OrtStatus),
    apiCreateTensorWithDataAsOrtValue :: Ptr OrtMemoryInfo -> Ptr Float -> CSize -> Ptr Int64 -> CSize -> CInt -> Ptr (Ptr OrtValue) -> IO (Ptr OrtStatus),
    apiGetTensorMutableData :: Ptr OrtValue -> Ptr (Ptr Float) -> IO (Ptr OrtStatus),
    apiGetTensorTypeAndShape :: Ptr OrtValue -> Ptr (Ptr OrtTensorTypeAndShapeInfo) -> IO (Ptr OrtStatus),
    apiGetDimensionsCount :: Ptr OrtTensorTypeAndShapeInfo -> Ptr CSize -> IO (Ptr OrtStatus),
    apiGetDimensions :: Ptr OrtTensorTypeAndShapeInfo -> Ptr Int64 -> CSize -> IO (Ptr OrtStatus),
    apiCreateCpuMemoryInfo :: CInt -> CInt -> Ptr (Ptr OrtMemoryInfo) -> IO (Ptr OrtStatus),
    apiAllocatorFree :: Ptr OrtAllocator -> Ptr () -> IO (Ptr OrtStatus),
    apiGetAllocatorWithDefaultOptions :: Ptr (Ptr OrtAllocator) -> IO (Ptr OrtStatus),
    apiCreateCUDAProviderOptions :: Ptr (Ptr OrtCUDAProviderOptionsV2) -> IO (Ptr OrtStatus),
    apiAppendCUDAV2 :: Ptr OrtSessionOptions -> Ptr OrtCUDAProviderOptionsV2 -> IO (Ptr OrtStatus),
    apiCreateTensorRTProviderOptions :: Ptr (Ptr OrtTensorRTProviderOptionsV2) -> IO (Ptr OrtStatus),
    apiUpdateTensorRTProviderOptions :: Ptr OrtTensorRTProviderOptionsV2 -> Ptr CString -> Ptr CString -> CSize -> IO (Ptr OrtStatus),
    apiAppendTensorRTV2 :: Ptr OrtSessionOptions -> Ptr OrtTensorRTProviderOptionsV2 -> IO (Ptr OrtStatus),
    apiReleaseEnv :: Ptr OrtEnv -> IO (),
    apiReleaseStatus :: Ptr OrtStatus -> IO (),
    apiReleaseSession :: Ptr OrtSession -> IO (),
    apiReleaseSessionOptions :: Ptr OrtSessionOptions -> IO (),
    apiReleaseValue :: Ptr OrtValue -> IO (),
    apiReleaseMemoryInfo :: Ptr OrtMemoryInfo -> IO (),
    apiReleaseTensorTypeAndShapeInfo :: Ptr OrtTensorTypeAndShapeInfo -> IO (),
    apiReleaseTypeInfo :: Ptr OrtTypeInfo -> IO (),
    apiReleaseCUDAProviderOptions :: Ptr OrtCUDAProviderOptionsV2 -> IO (),
    apiReleaseTensorRTProviderOptions :: Ptr OrtTensorRTProviderOptionsV2 -> IO ()
  }

-- | Peek a vtable entry by index (entries are pointers).
vtableAt :: Ptr a -> Int -> IO (FunPtr b)
vtableAt p idx = castFunPtr <$> peekByteOff p (idx * sizeOf (nullFunPtr :: FunPtr ()))

-- | dlopen the library at @libPath@ and resolve the vtable. Call once
-- per process; the resulting 'Api' is safe to share across threads.
loadApi :: FilePath -> IO Api
loadApi libPath = do
  dl <- dlopen libPath [RTLD_NOW, RTLD_GLOBAL]
  base <- mkGetApiBase =<< dlsym dl "OrtGetApiBase"
  getApiFn <- vtableAt base 0
  api <- mkGetApi getApiFn ortApiVersion
  versionFn <- vtableAt base 1
  let vf :: Int -> IO (FunPtr b)
      vf = vtableAt api
  fpGetErrorMessage <- vf idxGetErrorMessage
  fpCreateEnv <- vf idxCreateEnv
  fpCreateSession <- vf idxCreateSession
  fpRun <- vf idxRun
  fpCreateSessionOptions <- vf idxCreateSessionOptions
  fpSetSessionLogSeverityLevel <- vf idxSetSessionLogSeverityLevel
  fpSetIntraOpNumThreads <- vf idxSetIntraOpNumThreads
  fpDisableMemPattern <- vf idxDisableMemPattern
  fpDisableCpuMemArena <- vf idxDisableCpuMemArena
  fpSessionGetInputCount <- vf idxSessionGetInputCount
  fpSessionGetOutputCount <- vf idxSessionGetOutputCount
  fpSessionGetInputName <- vf idxSessionGetInputName
  fpSessionGetOutputName <- vf idxSessionGetOutputName
  fpSessionGetInputTypeInfo <- vf idxSessionGetInputTypeInfo
  fpSessionGetOutputTypeInfo <- vf idxSessionGetOutputTypeInfo
  fpCastTypeInfoToTensorInfo <- vf idxCastTypeInfoToTensorInfo
  fpCreateTensor <- vf idxCreateTensorWithDataAsOrtValue
  fpGetTensorMutableData <- vf idxGetTensorMutableData
  fpGetTensorTypeAndShape <- vf idxGetTensorTypeAndShape
  fpGetDimensionsCount <- vf idxGetDimensionsCount
  fpGetDimensions <- vf idxGetDimensions
  fpCreateCpuMemoryInfo <- vf idxCreateCpuMemoryInfo
  fpAllocatorFree <- vf idxAllocatorFree
  fpGetAllocatorWithDefaultOptions <- vf idxGetAllocatorWithDefaultOptions
  fpCreateCUDAProviderOptions <- vf idxCreateCUDAProviderOptions
  fpAppendCUDAV2 <- vf idxSessionOptionsAppendExecutionProviderCUDAV2
  fpCreateTensorRTProviderOptions <- vf idxCreateTensorRTProviderOptions
  fpUpdateTensorRTProviderOptions <- vf idxUpdateTensorRTProviderOptions
  fpAppendTensorRTV2 <- vf idxSessionOptionsAppendExecutionProviderTensorRTV2
  fpReleaseEnv <- vf idxReleaseEnv
  fpReleaseStatus <- vf idxReleaseStatus
  fpReleaseSession <- vf idxReleaseSession
  fpReleaseSessionOptions <- vf idxReleaseSessionOptions
  fpReleaseValue <- vf idxReleaseValue
  fpReleaseMemoryInfo <- vf idxReleaseMemoryInfo
  fpReleaseTensorTypeAndShapeInfo <- vf idxReleaseTensorTypeAndShapeInfo
  fpReleaseTypeInfo <- vf idxReleaseTypeInfo
  fpReleaseCUDAProviderOptions <- vf idxReleaseCUDAProviderOptions
  fpReleaseTensorRTProviderOptions <- vf idxReleaseTensorRTProviderOptions
  pure
    Api
      { apiVersionString = peekCString =<< mkGetVersionString versionFn,
        apiGetErrorMessage = peekCString <=< mkGetErrorMessage fpGetErrorMessage,
        apiCreateEnv = mkCreateEnv fpCreateEnv,
        apiCreateSession = mkCreateSession fpCreateSession,
        apiRun = mkRun fpRun,
        apiCreateSessionOptions = mkCreateSessionOptions fpCreateSessionOptions,
        apiSetSessionLogSeverityLevel = mkSessionOptInt fpSetSessionLogSeverityLevel,
        apiSetIntraOpNumThreads = mkSessionOptInt fpSetIntraOpNumThreads,
        apiDisableMemPattern = mkSessionOptVoid fpDisableMemPattern,
        apiDisableCpuMemArena = mkSessionOptVoid fpDisableCpuMemArena,
        apiSessionGetInputCount = mkSessionGetCount fpSessionGetInputCount,
        apiSessionGetOutputCount = mkSessionGetCount fpSessionGetOutputCount,
        apiSessionGetInputName = mkSessionGetName fpSessionGetInputName,
        apiSessionGetOutputName = mkSessionGetName fpSessionGetOutputName,
        apiSessionGetInputTypeInfo = mkSessionGetTypeInfo fpSessionGetInputTypeInfo,
        apiSessionGetOutputTypeInfo = mkSessionGetTypeInfo fpSessionGetOutputTypeInfo,
        apiCastTypeInfoToTensorInfo = mkCastTypeInfoToTensorInfo fpCastTypeInfoToTensorInfo,
        apiCreateTensorWithDataAsOrtValue = mkCreateTensorWithDataAsOrtValue fpCreateTensor,
        apiGetTensorMutableData = mkGetTensorMutableData fpGetTensorMutableData,
        apiGetTensorTypeAndShape = mkGetTensorTypeAndShape fpGetTensorTypeAndShape,
        apiGetDimensionsCount = mkGetDimensionsCount fpGetDimensionsCount,
        apiGetDimensions = mkGetDimensions fpGetDimensions,
        apiCreateCpuMemoryInfo = mkCreateCpuMemoryInfo fpCreateCpuMemoryInfo,
        apiAllocatorFree = mkAllocatorFree fpAllocatorFree,
        apiGetAllocatorWithDefaultOptions = mkGetAllocatorWithDefaultOptions fpGetAllocatorWithDefaultOptions,
        apiCreateCUDAProviderOptions = mkCreateCUDAProviderOptions fpCreateCUDAProviderOptions,
        apiAppendCUDAV2 = mkAppendCUDAV2 fpAppendCUDAV2,
        apiCreateTensorRTProviderOptions = mkCreateTensorRTProviderOptions fpCreateTensorRTProviderOptions,
        apiUpdateTensorRTProviderOptions = mkUpdateTensorRTProviderOptions fpUpdateTensorRTProviderOptions,
        apiAppendTensorRTV2 = mkAppendTensorRTV2 fpAppendTensorRTV2,
        apiReleaseEnv = mkRelease fpReleaseEnv,
        apiReleaseStatus = mkRelease fpReleaseStatus,
        apiReleaseSession = mkRelease fpReleaseSession,
        apiReleaseSessionOptions = mkRelease fpReleaseSessionOptions,
        apiReleaseValue = mkRelease fpReleaseValue,
        apiReleaseMemoryInfo = mkRelease fpReleaseMemoryInfo,
        apiReleaseTensorTypeAndShapeInfo = mkRelease fpReleaseTensorTypeAndShapeInfo,
        apiReleaseTypeInfo = mkRelease fpReleaseTypeInfo,
        apiReleaseCUDAProviderOptions = mkRelease fpReleaseCUDAProviderOptions,
        apiReleaseTensorRTProviderOptions = mkRelease fpReleaseTensorRTProviderOptions
      }

-- | Throw 'OrtError' if the call returned a non-null status.
checked :: Api -> Text -> IO (Ptr OrtStatus) -> IO ()
checked api what act = do
  st <- act
  when (st /= nullPtr) $ do
    msg <- apiGetErrorMessage api st
    apiReleaseStatus api st
    throwIO (OrtError what (T.pack msg))

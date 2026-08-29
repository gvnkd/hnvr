{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Custom server run for hnvr-admin: 'IHP.Server.run' is reused in
-- spirit but not in fact — it binds warp to all interfaces with no
-- host option, and the admin service must bind HNVR_ADMIN_LISTEN
-- (default 127.0.0.1) only (design_docs/13). Assembled from IHP's
-- exported building blocks; static files are served from APP_STATIC
-- (default hnvr-web/static) by a plain wai-app-static app behind the
-- same /static shortcut.
module AdminWeb.Server
  ( runAdmin,
  )
where

import AdminWeb.FrontController ()
import Control.Monad (forM_)
import Data.Maybe (fromMaybe)
import Data.String (fromString)
import qualified GHC.IO.Encoding as GhcIo
import qualified GHC.IO.Handle as GhcIo
import IHP.ControllerSupport ()
import IHP.ErrorController (errorHandlerMiddleware)
import IHP.FrameworkConfig
import IHP.ModelSupport (withModelContext)
import IHP.Prelude
import IHP.Server (application, initMiddlewareStack)
import IHP.Static (staticRouteShortcut)
import qualified Network.Wai.Application.Static as Static
import qualified Network.Wai.Handler.Warp as Warp
import qualified System.Environment as Env

-- | Like 'IHP.Server.run' but binds @HNVR_ADMIN_LISTEN@ (default
-- 127.0.0.1) and skips the PG listener (no autoRefresh in this app).
runAdmin :: ConfigBuilder -> IO ()
runAdmin configBuilder = do
  GhcIo.setLocaleEncoding GhcIo.utf8
  withFrameworkConfig configBuilder $ \(frameworkConfig :: FrameworkConfig) -> do
    withModelContext frameworkConfig.databaseUrl frameworkConfig.logger $ \modelContext -> do
      let ?modelContext = modelContext
      -- Initializers, run synchronously (IHP links them as asyncs; the
      -- admin's initializer set is small and bootstrap-critical).
      let ?context = frameworkConfig
      forM_ frameworkConfig.initializers $ \(Initializer onStartup) -> onStartup
      middleware <- initMiddlewareStack frameworkConfig modelContext Nothing
      staticDir <- fromMaybe "hnvr-web/static" <$> Env.lookupEnv "APP_STATIC"
      let staticApp = Static.staticApp (Static.defaultFileServerSettings staticDir)
          ihpApp = application staticApp frameworkConfig.requestLoggerMiddleware
          fullApp = staticRouteShortcut staticApp (middleware ihpApp)
      host <- fromMaybe "127.0.0.1" <$> Env.lookupEnv "HNVR_ADMIN_LISTEN"
      let settings =
            Warp.defaultSettings
              |> Warp.setPort frameworkConfig.appPort
              |> Warp.setHost (fromString host)
      Warp.runSettings settings (errorHandlerMiddleware frameworkConfig fullApp)

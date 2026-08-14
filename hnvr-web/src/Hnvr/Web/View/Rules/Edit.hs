{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /EditRule — prefilled rule form (shares 'ruleForm' with New).
module Hnvr.Web.View.Rules.Edit
  ( EditView (..),
  )
where

import Generated.Types
import Hnvr.Web.View.Layout (renderLayout)
import Hnvr.Web.View.Rules.New (ruleForm)
import IHP.ViewPrelude

data EditView = EditView
  { rule :: Rule,
    camera :: Camera
  }

instance View EditView where
  html EditView {..} =
    renderLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>Edit rule · <span class="font-mono">{camera.slug}</span></h1>
          <div class="subtitle">{rule.name}</div>
        </div>
      </div>
      {ruleForm camera (Just rule) ("/UpdateRule?ruleId=" <> rid)}
    |]
    where
      rid = tshow (rule |> get #id)

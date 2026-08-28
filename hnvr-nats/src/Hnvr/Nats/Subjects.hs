{-# LANGUAGE OverloadedStrings #-}

-- | Canonical NATS subject names used throughout HNVR.
--
-- Keeping them in one place makes it trivial to grep for the producer or
-- consumer of any given subject, and prevents typos at publish/subscribe sites.
--
-- See @design_docs/01-architecture.md@ "NATS subjects" table for semantics
-- (durability, direction, payload schema).
module Hnvr.Nats.Subjects
  ( events,
    commandAssign,
    commandControl,
    commandPtz,
    commandSnapshot,
    framesCamera,
    health,
    configCameras,
    ptzStatus,
    ptzAudit,
    leader,
  )
where

import Data.Text (Text)

-- | JetStream-durable catch-all events stream.
-- Kinds: @segment_written@, @line_crossed@, @zone_enter@, @zone_exit@,
-- @track_start@, @track_end@, @system@.
events :: Text
events = "hnvr.events"

-- | @hnvr.frames.<cameraId>@ — analyzer → leader, throttled JPEG of the
-- latest analysis frame (body = raw JPEG bytes). Keeps the leader's
-- dashboard wall (/debug-frame) fed for cameras analyzed on remote
-- nodes, where the leader has no local analyzer.
framesCamera :: Text -> Text
framesCamera camId = "hnvr.frames." <> camId

-- | @hnvr.commands.assign.<cam>@ — leader → all hosts (reassign a camera).
commandAssign :: Text -> Text
commandAssign camSlug = "hnvr.commands.assign." <> camSlug

-- | @hnvr.commands.control.<host>.<cam>.<action>@ — leader → host.
commandControl :: Text -> Text -> Text -> Text
commandControl host cam action =
  "hnvr.commands.control." <> host <> "." <> cam <> "." <> action

-- | @hnvr.commands.ptz.<cam>@ — UI/leader → host owning the camera.
commandPtz :: Text -> Text
commandPtz camSlug = "hnvr.commands.ptz." <> camSlug

-- | @hnvr.commands.snapshot.<host>@ — node → leader request/reply.
-- Node publishes this on boot (and on any subsequent re-resolve) with a
-- generated inbox as reply-to. The leader's 'Hnvr.Web.SnapshotResponder'
-- replies with the JSON list of cameras currently assigned to that host
-- so the node can spawn 'CaptureWorker's for them. Bridges the lack of
-- JetStream durability (Phase 0 deferral) for the initial-state problem.
commandSnapshot :: Text -> Text
commandSnapshot host = "hnvr.commands.snapshot." <> host

-- | @hnvr.health.<host>@ — node → all. Max-age 15s.
health :: Text -> Text
health host = "hnvr.health." <> host

-- | @hnvr.config.cameras.<slug>@ — leader → all (broadcast on row change).
configCameras :: Text -> Text
configCameras slug = "hnvr.config.cameras." <> slug

-- | @hnvr.ptz.status.<cam>@ — host owning cam → all. Max-age 2s.
ptzStatus :: Text -> Text
ptzStatus camSlug = "hnvr.ptz.status." <> camSlug

-- | @hnvr.ptz.audit@ — host owning cam → leader. One 'PtzAuditRecord'
-- per executed command; the leader's PtzAuditWriter persists rows
-- (nodes have no DB access).
ptzAudit :: Text
ptzAudit = "hnvr.ptz.audit"

-- | @hnvr.leader@ — JetStream KV bucket with TTL 10s for leader lease.
leader :: Text
leader = "hnvr.leader"

# Metabase, the optional service of the compose profile metabase, pinned to a
# registry digest (multi-platform index). Tagged boost-togo/metabase:<version> so
# that an offline server finds it by tag after `docker load`, as postgres.Dockerfile
# explains.
FROM metabase/metabase:v0.63.20.2@sha256:536952360c83dc6f222a37c73453db502c83c3d5adb1a99e7c8731e2ca7d0b97

# Architecture and lineage

Owner: LUNASaan project team
Last updated: 2026-10-21

## Intended flow

`approved source → landing volume → bronze raw records + metadata → silver validated and standardised records → gold decision-facing marts → dashboard`

The quality layer should record validations, thresholds, results, severity, failure actions, build identifiers, and input versions at each publish boundary.

## What is implemented on `main`

The repository contains the layer folder structure, a PSGC source configuration, and a schema-create script. The layer setup scripts are empty comments and no ingestion, transformation, gold model, quality gate, dashboard build, or lineage evidence is present in this revision.

## Minimum lineage contract before publishing

Every published row or aggregate must be traceable to a source version/checksum, retrieval date, source geography/time definition, transformation version, quality run, and build run. Tables need a stated grain, keys, unit, denominator where applicable, and a geographic matching rule. Exclusions must be counted and explained.

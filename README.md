<img width="1375" height="510" alt="LUNASaan" src="https://github.com/user-attachments/assets/0cea976e-f1a0-456a-98cf-6a3849edeab2" />

# LUNASaan?
### Philippine Public Health Platform

**Tamang datos. Tamang lugar. Tamang tugon.**

## Project Overview
Short 2–3 sentence summary of the project.

## Business Problem
Briefly explain the public-health problem the project is trying to solve.

## Key Questions
- Question 1
- Question 2
- Question 3
- Question 4

## Data Sources
| Source | Purpose |
|---|---|
| DOH Health Facilities Database | |
| PSGC / HDX | |
| PSA Population Statistics | |
| Dengue Dataset | |

## Architecture
Source → Landing → Bronze → Silver → Gold → Dashboard

Short description of each layer if needed.

## Data Model
Brief summary of the Gold model.

- Fact tables:
- Dimension tables:
- Main grain:

See `docs/data_model.md` for details.

## Data Quality
Briefly list the main checks:

- Null validation
- Duplicate checks
- Referential integrity
- Geographic hierarchy validation
- Row-count reconciliation
- Idempotency checks

See `docs/validation.md` for details.

## Repository Structure
```text
├── notebooks/
├── src/
├── tests/
├── dashboards/
└── docs/

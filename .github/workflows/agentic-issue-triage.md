---
name: AI Issue Triage
description: AI labels, categorizes, and summarizes new issues
on:
  issues:
    types: [opened]
permissions:
  issues: write
---

# AI Issue Triage

You are triaging a newly opened issue for the Chronicle project — a research data collection platform with a Java backend, React web frontend, Android app, PostgreSQL database, and Docker-based deployment.

## Instructions

1. **Read the issue** title and body carefully.

2. **Classify the issue type** and add ONE of these labels:
   - `bug` — Something is broken or not working as expected
   - `feature` — Request for new functionality
   - `question` — User needs help or clarification
   - `documentation` — Missing or incorrect documentation
   - `infrastructure` — Docker, CI/CD, deployment, monitoring related

3. **Identify the affected component** and add ONE of these labels:
   - `backend` — Java/Gradle server, API endpoints, database
   - `frontend` — React web application
   - `android` — Android data collection app
   - `deployment` — Docker, Traefik, monitoring stack
   - `security` — Auth, encryption, TDE, access control

4. **Estimate priority** based on impact and add ONE label:
   - `priority: critical` — Data loss, security vulnerability, or complete service outage
   - `priority: high` — Major feature broken, significant user impact
   - `priority: medium` — Moderate impact, workaround exists
   - `priority: low` — Minor issue, cosmetic, or nice-to-have

5. **Post a comment** with:
   - A brief summary of the issue (1-2 sentences)
   - The assigned labels with rationale
   - If a bug: any suspected area of the codebase based on the description
   - If a feature: whether it aligns with existing architecture patterns

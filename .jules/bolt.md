## 2025-05-23 - [Participants Table Optimization]
**Learning:** In large data tables, nested O(N) searches (like `.find()`) inside row components lead to O(N^2) complexity. Pre-processing data into lookup maps at the parent level and using `React.memo` for rows significantly improves rendering performance.
**Action:** Always prefer O(1) lookup maps over O(N) array searches in list/table rendering paths.

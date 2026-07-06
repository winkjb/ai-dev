# ai-dev Workspace

This directory is used as a development environment for business automation projects.

## Conventions

### context.md Files
Every folder in this workspace should contain a `context.md` file that describes the purpose of that folder, what it contains, and any relevant notes. This helps Claude (and collaborators) quickly orient to what's in each directory without having to read every file.

### log.md Files

To be prepared.

### Relative Paths Only
All code and apps created in this workspace must use **relative paths**, never static/absolute paths. This ensures portability — workflows, scripts, and apps should work regardless of where the workspace is cloned or moved on any machine.

Bad: `C:\GitHub\directory\data\file.csv`
Good: `./data/file.csv` or `../data/file.csv`

### CHANGELOG.md Maintenance

To be prepared.

### BOOTSTRAP.md Maintenance

To be prepared.
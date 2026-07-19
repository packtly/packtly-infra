# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!--
## [x.y.z] - yyyy-mm-dd
### Added
### Changed
### Removed
### Fixed
-->
<!--
RegEx for release version from file
r"^\#\# \[\d{1,}[.]\d{1,}[.]\d{1,}\] \- \d{4}\-\d{2}-\d{2}$"
-->
## [1.1.0] - 2026-07-19
### Changed
- Add ansible lint
- linted ansible code and fixed issues
- correct formatting of SSH key generation commands in create_secrets.yml
- add packtly service user password handling
- add create scripts for packtly service journal and status checks
- fix: pass container environment to gpg-import and aptly-api services
- fix: change file permissions for htpasswd to 644 for broader access
- fix: publish_repo script to handle single and multiple repos

## [1.0.0] - 2026-05-05
### Added
- Add initial implementation of Packtly infrastructure
- Add initial infrastructure setup for Packtly project
- Add initial Ansible roles and configurations for Packtly infrastructure
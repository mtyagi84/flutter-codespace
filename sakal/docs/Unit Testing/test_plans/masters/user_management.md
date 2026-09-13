# User Management — Test Plan
Module: AD — Settings | Group: User Management | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## AD-USR — User Management (`/setup/users`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| USR-01 | Create a new user | Fill required fields, set default location, Save | User appears in list; can log in with `must_change_password` forcing a reset on first login | High | Not Started | |
| USR-02 | Deactivate a user | Deactivate an active user | User can no longer log in; historical records still show their name | High | Not Started | |
| USR-03 | Duplicate username blocked | Create a user with an existing username | Blocked with a clear message | Med | Not Started | |
| USR-04 | Reset a user's password (admin) | Admin resets another user's password | User can log in with the new password | High | Not Started | |

## AD-PRM — User Permissions (`/setup/permissions`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRM-01 | Grant view+add on a feature | Toggle view_allowed then add_allowed for one feature | Cascade: add ON auto-enables view (per `feedback_erp_architecture_principles`'s permission_cascade rules) | High | Not Started | |
| PRM-02 | Revoke view clears everything | Turn view OFF on a feature that has add/edit/approve ON | All flags clear for that feature | High | Not Started | |
| PRM-03 | Missing row = fully denied | Check a feature never explicitly granted | User cannot see the menu item at all | High | Not Started | |
| PRM-04 | Server-side re-check, not just UI | Grant a user UI access to Approve via a stale cached permission, then revoke server-side | The Approve RPC itself rejects with `APPROVE_NOT_PERMITTED`, not just a hidden button | High | Not Started | |

## AD-ULS — User Location Setup (`/setup/user-location-access`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| ULS-01 | Restrict a user to one location | Assign only Location A | User cannot select Location B in any transaction screen | High | Not Started | |
| ULS-02 | Multi-location user | Assign 2+ locations | User can switch between them; each screen's Location picker only shows assigned locations | Med | Not Started | |

## AD-MST — Master Menu (`/setup/master-menu`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| MST-01 | Add a menu entry | Add a new feature_code/screen_name row | Appears in the sidebar for users with that permission | Med | Not Started | |
| MST-02 | Copy allowed (`copy_allowed=true`) | Duplicate a menu structure | New entry independently editable | Low | Not Started | |
| MST-03 | Edit an existing route | Change a screen's `screen_name` | Sidebar link now points to the new route; confirm the route actually exists in `app_router.dart` first (a past real bug: PR-PO pointed at a dead route) | High | Not Started | |

---
## Cross-Cutting Checklist reminder
CCC #6 (permission gating) is the centerpiece of this whole group — test it thoroughly,
including the server-side re-check (PRM-04), not just what the sidebar shows.

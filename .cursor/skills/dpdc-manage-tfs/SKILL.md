---
name: dpdc-manage-tfs
description: >-
  Use for any TFS / TFVC work: get latest, check in, or review local changes against the server. Compares the current project with the TFS server (ignores checkout state), skips dot-folders and defined exclusions, keeps files in their server encoding, reports conflicts, asks the user when unsure, and checks in everything as a single approved changeset. Also writes TFS-ready Pakhsh SQL stored procedures.
author: "Armin Dashti"
uuid: 3fde00f1-c7bc-42af-b49f-6bee4c791205
---
# Manage TFS

# Part 1: Description and rules

## When to use

- Get latest, `tf get`, workspace sync: **Get mode**.
- Check in, submit a changeset, review local changes against the server: **Check-in mode**.
- Write or update a Pakhsh / DPDC stored procedure for TFS: **SQL mode**.

## Core rules

1. **Default project.** Work on the project (folder) the skill is run from. Use another project only when the user names one.
2. **Server is the reference, not checkout.** Never rely on checkout state or `tf status`. Always compare the local folder with the TFS server to find **added**, **edited**, and **deleted** files, whether or not they were checked out.
3. **Exclusions are always applied.** Skip `.cursor`, `.git`, `.armin`, `.argent`, and any file or folder whose name starts with a dot, plus any extra exclusions the user has defined. Excluded items are never pended, checked in, converted, or reported as changes.
4. **Encoding follows the server.** Every file is stored locally in the same encoding as its server version (including BOM / no BOM). Before check-in, if a local file's encoding differs from the server version, convert it to the server encoding. New files with no server version: keep their current encoding and mention it in the proposal.
5. **Conflicts go to the user.** When the server version changed since the local copy was taken (both sides changed), or a get would overwrite local edits, stop and tell the user file by file. Never resolve, overwrite, or discard on your own.
6. **One changeset.** All approved changes go into a single `tf checkin`, no matter how many files.
7. **Ask when unsure.** For any question or ambiguity (scope, a file's intent, an unexpected delete, a conflict), ask the user instead of guessing.
8. **Approval before check-in.** Show the proposal (Part 2, step C5) and run `tf checkin` only after the user says yes.
9. **Star comment.** If the user says "make comment star" (or "star the comment"), change the check-in comment to start with `********** ` followed by the comment text, e.g. `**********`.
10. **Credentials.** Never hardcode, print, or log passwords.

## Never

1. Run `tf` commands without confirming the workspace mapping.
2. Check in without the Added | Edited | Deleted grid and explicit approval.
3. Split one approved check-in into several changesets.
4. Use `tf get /force` or overwrite files that have local edits without approval.
5. Include excluded files or folders.
6. Leave a file in an encoding different from its server version.

# Part 2: Commands and tutorial

## A. Setup (all modes)

Connection comes from environment variables:

| Variable | Purpose |
|----------|---------|
| `TFS` | Path to `tf.exe` (else use Visual Studio Team Explorer `TF.exe`) |
| `TFS_ADDRESS` | Collection / team project URL |
| `TFS_USERNAME` | TFS login user |
| `TFS_PASSWORD` | Secret, used only as `$env:TFS_PASSWORD` |

Auth: prefer Windows integrated / cached credentials. If needed add `/login:$env:TFS_USERNAME,$env:TFS_PASSWORD`.

Confirm the mapping from the project root (the current project unless the user named another):

```powershell
cd <PROJECT_ROOT>
tf workfold .
tf workspaces
```

Report project name, collection, server path (`$/...`), and local root. Never reuse paths from an old chat.

## B. Get mode

1. Compare local with server first (step C1). If local edits exist, list them and warn.
2. Get latest:

```powershell
tf get . /recursive /noprompt
```

3. Never use `/force` on files with local edits unless the user approves.
4. Report conflicts to the user; never discard them silently.
5. After the get, check the encoding of updated files against the server (step C3) and fix any mismatch.
6. Report updated, up-to-date, and conflicted files.

## C. Check-in mode

**C1. Compare local with the server** (ignore checkout state):

```powershell
tf vc folderdiff . <SERVER_ROOT> /recursive /noprompt /view:different,sourceOnly,targetOnly
```

| folderdiff result | Meaning |
|-------------------|---------|
| Different contents | **Edited** (pend edit even if not checked out) |
| Local only | **Added** (`tf add`) |
| Server only | **Deleted** (`tf delete`), confirm with the user if it looks unintentional |

**C2. Remove exclusions.** Drop every path that contains a segment starting with `.` (e.g. `.cursor`, `.git`, `.armin`, `.argent`) and any user-defined exclusion.

**C3. Check conflicts and encoding.** For each edited file:

```powershell
tf properties <file>          # shows server version, latest version, and Encoding
tf history <file> /stopafter:1 /noprompt
```

- If the latest server version is newer than the local workspace version and the server content also changed: **conflict**. Stop and tell the user.
- If the local encoding differs from the server encoding, convert the local file to the server encoding (keep the text, change only the encoding):

```powershell
$text = [IO.File]::ReadAllText($path)                          # detects current encoding
$enc  = [Text.Encoding]::GetEncoding(<server codepage>)        # e.g. 65001 UTF-8, 1256 Arabic/Persian, 1200 UTF-16
# UTF-8 without BOM: $enc = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($path, $text, $enc)
```

**C4. Data-safe pend.** Local content is the source of truth.

1. SHA-256 hash every candidate (after encoding conversion).
2. Pend: `tf checkout <paths>`, `tf add <paths>`, `tf delete <paths>`. No `tf get /force` on them.
3. Re-hash. Any change means stop and tell the user.

**C5. Propose** (required):

```markdown
### Proposed comment
<ProjectName>: [1. <CHANGE-1>] [2. <CHANGE-2>]

### Target
- Collection / Server $/path / Workspace / Scope: <ProjectName> only

### Encoding
- Converted to server encoding: <file (from -> to)> or none

### Conflicts
- <file: description> or none

### What will happen
| Added | Edited | Deleted |
|-------|--------|---------|
| path or - | path or - | path or - |

Counts: Added N, Edited N, Deleted N, total N (one changeset)

Reply **yes** to check in, or change comment / scope.
```

Comment phrases describe the purpose, not file names. Apply the star rule if asked.

**C6. Check in, one changeset:**

```powershell
tf checkin <all approved paths> /comment:"<comment>" /noprompt
```

- If a pended edit's local file is missing (`Could not find file`): `tf undo <file>`, `tf get <file> /force`, `tf delete <file>`, then re-propose.
- Report the changeset number.

**C7. Verify.** Run step C1 again: no in-scope differences should remain. Re-hash approved paths (must match), and confirm encodings match the server.

## D. SQL mode (stored procedures)

TFS-compliant DPDC / Pakhsh procedures. Output **only** SQL code.

1. Start with:

```sql
USE [PAKHSH]
GO
```

2. Use `ALTER PROCEDURE` for existing store procedures.
3. Keep commented sample calls such as `--EXEC ...`; update them to match the latest changes.
4. Save the file in the server encoding of that file (rule 4).
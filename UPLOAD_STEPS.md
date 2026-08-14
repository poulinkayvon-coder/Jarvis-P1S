# Exact upload steps

## 1. Open your repository

Open:
https://github.com/poulinkayvon-coder/Jarvis-P1S

Do not send anyone your password or Apple credentials.

## 2. Upload the ZIP contents

GitHub's web interface cannot upload a ZIP and automatically turn it into the project files, so:

1. Download `JarvisP1S_Upgraded.zip`.
2. Extract it on your iPhone or another device.
3. Open your repository on GitHub.
4. Tap **Add file**.
5. Choose **Upload files**.
6. Select ALL of the extracted files and folders, including:
   - `.github`
   - `JarvisP1S`
   - `JarvisP1STests`
   - `Info.plist`
   - `README.md`
7. Commit the changes directly to `main`.

If GitHub's mobile interface hides the upload option, use GitHub in Safari and request the desktop website.

## 3. Check Actions

After the commit:
1. Open the repository.
2. Open **Actions**.
3. Select **Jarvis iOS Build**.
4. Open the newest run.
5. Wait for the macOS runner to finish.

A green check means the workflow completed.

## 4. Do NOT add secrets yet

Do not put your:
- Apple password
- Apple verification codes
- P1S access code
- private signing certificate
- API keys

into source files or commit them to the repository.

## 5. Important limitation

This workflow is a free CI/build path. It does NOT magically provide a permanent installable iPhone app.

GitHub documents that standard macOS runners are free and unlimited for public repositories. Apple documents that a free Personal Team can provision apps for personal-device testing, but those provisioning profiles expire after 7 days and require rebuilding/reinstalling.

Therefore, after the first successful Actions build, the next engineering step is the device-signing/install path.

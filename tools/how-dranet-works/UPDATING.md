# Update the how-dranet-works page for a new dranet release

The page is `static/how-dranet-works/index.html`. Hugo copies it to `/how-dranet-works/` without changes.
The page is pinned to one dranet release tag. All code links and line numbers refer to that tag.

## Steps

1. Get the new tag in a dranet checkout.

   ```bash
   git -C ~/Documents/Repos/dranet-pf-oke/dranet fetch --tags origin
   ```

2. List the merges between the old tag and the new tag. Read each one that changes behavior.

   ```bash
   git -C ~/Documents/Repos/dranet-pf-oke/dranet log --oneline --first-parent v1.5.0..v1.6.0
   ```

3. Edit the step text in the `STEPS` array of the page for each behavior change. Edit the reference sections below the player if they are affected.

4. Replace the old tag with the new tag in the whole page. Update the release date in the header line and in the footer.

   ```bash
   sed -i '' 's/v1\.5\.0/v1.6.0/g' static/how-dranet-works/index.html
   ```

5. Run the reference check. It prints `FAIL` for each reference whose line no longer holds the named function.

   ```bash
   tools/how-dranet-works/check-refs.sh ~/Documents/Repos/dranet-pf-oke/dranet
   ```

6. Fix each `FAIL` line number in the page. Run the check again until it passes. Read the `REVIEW` lines one time, because the script cannot check them by name.

7. Build the site and open the page.

   ```bash
   hugo server
   ```

   Open `http://localhost:1313/how-dranet-works/`. Go through the 15 steps for both example nodes.

8. Commit and push. A push to `main` publishes the site.

## Notes

- The example addresses in the page (`10.208.0.25/12`, table 100) follow the OKE provider defaults. Check them when the OKE provider changes.
- The script reads the tag from the `RELEASE` constant in the page. A second argument overrides it.

# Update the how-dranet-works page for a new dranet release

The page is `static/how-dranet-works/index.html`. Hugo copies it to `/how-dranet-works/` without changes.
The page is pinned to one dranet release tag. All code links and line numbers refer to that tag.

## Steps

Set the old tag and the new tag first. The commands below use them.

```bash
OLD=v1.5.0
NEW=v1.6.0
```

1. Get the new tag in a dranet checkout.

   ```bash
   git -C ~/Documents/Repos/dranet-pf-oke/dranet fetch --tags origin
   ```

2. List the merges between the old tag and the new tag. Read each one that changes behavior.

   ```bash
   git -C ~/Documents/Repos/dranet-pf-oke/dranet log --oneline --first-parent "$OLD..$NEW"
   ```

3. Edit the step text in the `STEPS` array of the page for each behavior change. Check these parts too, because they also hold release-dependent values: `SAMPLES` (the YAML examples), `SCN` and `stateFor` (the example interfaces and their state), and the reference sections below the player.

4. Replace the old tag with the new tag in the whole page. Update the release date in the header line and in the footer.

   ```bash
   sed -i '' "s/${OLD//./\\.}/$NEW/g" static/how-dranet-works/index.html
   grep -c "$NEW" static/how-dranet-works/index.html
   ```

   The count must not be 0. This `sed -i ''` form is for macOS.

5. Run the reference check with the new tag. It prints `FAIL` when the named function or type is not defined on the referenced line, when the page still links to another tag, or when a link text shows another line number than the link.

   ```bash
   tools/how-dranet-works/check-refs.sh ~/Documents/Repos/dranet-pf-oke/dranet "$NEW"
   ```

6. Fix each `FAIL` line number in the page. A link in the reference sections shows its line number two times, in the `#L` part and in the visible text. Change both. Run the check again until it passes. Read the `REVIEW` lines one time, because the script cannot check them by name.

7. Build the site and open the page.

   ```bash
   hugo server
   ```

   Open `http://localhost:1313/how-dranet-works/`. Go through the 15 steps for both example nodes.

8. Commit and push. A push to `main` publishes the site.

## Notes

- The example addresses in the page (`10.208.0.25/12`, table 100) follow the OKE provider defaults. Check them when the OKE provider changes.
- The script reads the tag from the `RELEASE` constant in the page. The second argument is a guard. The check fails if the page links to any other tag.
- The page loads GoatCounter with its own script tag, because the theme head is not used for this page.

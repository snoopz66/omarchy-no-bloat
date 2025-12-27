for script in "$OMARCHY_INSTALL/custom"/*.sh; do
  if [[ -f "$script" ]]; then
    run_logged "$script"
  fi
done

import json, os, sys

def clean():
    if len(sys.argv) < 2:
        print("FOUT: Geen pad meegegeven aan script")
        sys.exit(1)

    config_dir = sys.argv[1]
    storage_path = os.path.join(config_dir, ".storage")
    files = ['core.config_entries', 'core.entity_registry', 'core.device_registry']

    print(f"--- START SURGICAL CLEANUP IN {storage_path} ---")

    for f_name in files:
        path = os.path.join(storage_path, f_name)
        if not os.path.exists(path):
            print(f"SKIPPED: {f_name} not found on path {path}")
            continue

        print(f"PROCESSING : {f_name}")
        with open(path, 'r') as f:
            try:
                data = json.load(f)
            except Exception as e:
                print(f"JSON ERROR in {f_name}: {e}")
                continue

        original_count = 0
        new_count = 0

        if f_name == 'core.config_entries':
            original_count = len(data['data']['entries'])
            entries = data['data']['entries']
            # Match on domain as seen in your screenshot ("domain":"backup")
            data['data']['entries'] = [e for e in entries if e.get('domain') not in ['backup', 'hassio']]
            new_count = len(data['data']['entries'])

            removed = [e.get('domain') for e in entries if e.get('domain') in ['backup', 'hassio']]
            if removed:
                print(f"  REMOVED from config_entries: {removed}")

        elif f_name == 'core.entity_registry':
            original_count = len(data['data']['entities'])
            entities = data['data']['entities']
            # Match on platform as seen in your screenshot ("platform":"hassio")
            data['data']['entities'] = [e for e in entities if e.get('platform') not in ['hassio', 'backup']]
            new_count = len(data['data']['entities'])
            if original_count != new_count:
                print(f"  REMOVED: {original_count - new_count} entities with platform 'hassio' or 'backup'")

        elif f_name == 'core.device_registry':
            original_count = len(data['data']['devices'])
            devices = data['data']['devices']
            # Deep check for identifiers: "identifiers":[["backup","backup_manager"]]
            # This looks into each part of the nested identifier lists
            data['data']['devices'] = [d for d in devices if not any(
                any(x in str(part).lower() for x in ['hassio', 'backup'])
                for ident in d.get('identifiers', []) for part in ident
            )]
            new_count = len(data['data']['devices'])
            if original_count != new_count:
                print(f"  REMOVED: {original_count - new_count} devices related to 'hassio' or 'backup'")

        # Store only if something is really changed
        if original_count != new_count:
            with open(path, 'w') as f:
                json.dump(data, f, indent=2)
            print(f"  SUCCESS: {f_name} is changed and stored.")
        else:
            print(f"  NO CHANGES: No hassio/backup stuff found in {f_name}")

    print("--- CLEANUP COMPLETE ---")

if __name__ == "__main__":
    clean()
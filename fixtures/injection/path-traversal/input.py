def read_user_file(base_dir, user_path):
    with open(base_dir + "/" + user_path) as f:
        return f.read()

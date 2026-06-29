import yaml

def load_config(user_text):
    return yaml.load(user_text, Loader=yaml.UnsafeLoader)

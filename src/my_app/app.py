from time import sleep
from fling.start import app, start_app, environ

domain_name = "localhost.localdomain"


def main():
    sleep(3)  # This allows us to see the loading screen
    return "<h1>My Sample App</h1>"


environ.ensure_keys(["EXAMPLE_KEY"])
start_app(main, domain_name=domain_name)
if __name__ == "__main__":
    app.run()

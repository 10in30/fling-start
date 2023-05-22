from time import sleep
from fling.start import app, start_app, environ

domain_name = "demo"


def main():
    print("In main for the demo app")
    sleep(1)  # This allows us to see the loading screen
    return "<h1>My Sample App - Getting Better and Best</h1>"


# environ.ensure_keys(["EXAMPLE_KEY"])
start_app(main, domain_name=domain_name)

# if __name__ == "__main__":
#     app.run(host=f"unix:///tmp/{domain_name}.soc", debug=False, use_reloader=True)

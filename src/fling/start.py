from flask import Flask, Blueprint, render_template


start = Blueprint(
    "fling-starter",
    __name__,
    static_folder="static/start",
    static_url_path="/static/start",
    template_folder="templates"
)


@start.route("/")
def index():
    return render_template("start/index.html")


@start.route("/x3d")
def x3d():
    return render_template("start/x3d.html")


app = Flask("starter")
app.register_blueprint(start)

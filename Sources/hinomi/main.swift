import AppKit
import HinomiCore

let hinomiVersion = "0.1.0"

let arguments = Array(CommandLine.arguments.dropFirst())
let subcommand = arguments.first ?? ""

switch subcommand {
case "":
    HinomiApp.run()
case "run":
    HinomiApp.run()
case "install-hooks":
    CLI.installHooks(arguments: Array(arguments.dropFirst()))
case "uninstall-hooks":
    CLI.uninstallHooks(arguments: Array(arguments.dropFirst()))
case "status":
    CLI.status()
case "hook":
    CLI.hook(arguments: Array(arguments.dropFirst()))
case "help", "--help", "-h":
    CLI.usage()
case "version", "--version", "-v":
    print("hinomi \(hinomiVersion)")
default:
    FileHandle.standardError.write(Data("hinomi: 未知のサブコマンド '\(subcommand)'\n".utf8))
    CLI.usage()
    exit(64)
}

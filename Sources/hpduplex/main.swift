import Foundation
import Darwin

setvbuf(stdout, nil, _IONBF, 0)
setvbuf(stderr, nil, _IONBF, 0)

do {
    try CLI.run(Array(CommandLine.arguments.dropFirst()))
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

    var canceled = false
    if let cliError = error as? CLIError, case .canceled = cliError {
        canceled = true
    }
    if !canceled, CommandLine.arguments.contains("--gui") {
        Interaction.guiAlert("HP 136w 手动双面", message)
    }

    FileHandle.standardError.write(Data(("错误: " + message + "\n").utf8))
    exit(1)
}
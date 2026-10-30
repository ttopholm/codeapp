//
//  ClaudeAssistantExtension.swift
//  Code
//
//  Adds a Claude assistant to the activity bar. Claude can read, search and edit
//  files in the current workspace through WorkSpaceStorage, so it works with
//  local folders as well as remote (SFTP/FTP) workspaces.
//

import SwiftUI

class ClaudeAssistantExtension: CodeAppExtension {
    private var agent: ClaudeAgent?

    override func onInitialize(app: MainApp, contribution: CodeAppExtension.Contribution) {
        let agent = MainActor.assumeIsolated { () -> ClaudeAgent in
            let agent = ClaudeAgent()
            agent.attach(app: app)
            return agent
        }
        self.agent = agent

        var item = ActivityBarItem(
            itemID: "CLAUDE_ASSISTANT",
            iconSystemName: "sparkles",
            title: "Claude",
            shortcutKey: "l",
            modifiers: [.command, .shift],
            view: AnyView(ClaudeContainer().environmentObject(agent)),
            contextMenuItems: nil,
            bubble: {
                // Activity bar is rendered on the main thread.
                MainActor.assumeIsolated {
                    agent.pendingApproval != nil ? .systemImage("exclamationmark") : nil
                }
            },
            isVisible: { true }
        )
        item.positionPrecedence = -20
        contribution.activityBar.registerItem(item: item)
    }

    override func onWorkSpaceStorageChanged(newUrl: URL) {
        guard let agent else { return }
        Task { @MainActor in
            agent.workspaceChanged()
        }
    }
}

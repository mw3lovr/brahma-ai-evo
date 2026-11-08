import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var state: AgentState
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if state.chatHistory.isEmpty {
                            Text("Messages you send here go to Brahma on your PC.")
                                .font(.callout)
                                .foregroundStyle(Palette.muted)
                                .padding(.top, 40)
                        }
                        ForEach(state.chatHistory) { message in
                            ChatBubble(message: message).id(message.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: state.chatHistory.count) { _ in
                    if let last = state.chatHistory.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            HStack(spacing: 10) {
                TextField("Message Brahma...", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 24))
                    .submitLabel(.send)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                        .foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .background(canSend ? Palette.accent : Color(white: 0.2), in: Circle())
                }
                .disabled(!canSend)
            }
            .padding(12)
            .background(.ultraThinMaterial)
        }
    }

    private var canSend: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        BrahmaWebSocketClient.shared.sendChatMessage(text)
        input = ""
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 48) }
            if !isUser {
                Text("B")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 30, height: 30)
                    .background(Palette.accent, in: Circle())
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .textSelection(.enabled)
                    .foregroundStyle(isUser ? Color.black : Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isUser ? Palette.accent : Color(white: 0.13), in: RoundedRectangle(cornerRadius: 18))
                Text(isUser ? message.status : message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
            }
            if !isUser { Spacer(minLength: 48) }
        }
    }
}

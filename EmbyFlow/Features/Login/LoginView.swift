import SwiftUI
import UIKit

struct LoginView: View {
    @EnvironmentObject private var session: SessionStore

    /// true 时作为「添加账号」表单弹出（带取消按钮，成功后自动关闭）。
    var isAddingAccount = false
    var onFinish: (() -> Void)?

    @State private var address = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    if isAddingAccount {
                        HStack {
                            Button(action: { onFinish?() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                    Text("返回")
                                }
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Theme.accent)
                            }
                            Spacer(minLength: 0)
                        }
                    }

                    header
                    form

                    if let error = session.errorMessage {
                        ErrorBanner(message: error, onRetry: nil)
                    }

                    connectButton
                    recentServers
                }
                .padding(24)
            }
        }
        .onAppear { session.restoreSession() }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color(red: 0.50, green: 0.93, blue: 0.60),
                                Color(red: 0.15, green: 0.60, blue: 0.34)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 88, height: 88)
                    .shadow(color: Theme.accent.opacity(0.30), radius: 16, x: 0, y: 8)

                Image(systemName: "play.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(Color(red: 0.04, green: 0.05, blue: 0.06))
                    .offset(x: 3)
            }

            Text("EmbyFlow")
                .font(.system(size: 27, weight: .bold))
                .foregroundColor(.white)
            Text(isAddingAccount ? "添加一个 Emby 账号" : "连接你的 Emby 服务器")
                .font(.system(size: 13))
                .foregroundColor(Theme.secondaryText)
        }
        .padding(.top, 26)
        .padding(.bottom, 10)
    }

    private var form: some View {
        VStack(spacing: 12) {
            InputField(
                icon: "server.rack",
                placeholder: "服务器地址，例如 192.168.1.10:8096",
                text: $address,
                keyboard: .URL
            )
            InputField(icon: "person", placeholder: "用户名", text: $username)
            InputField(icon: "lock", placeholder: "密码", text: $password, isSecure: true)
        }
    }

    private var connectButton: some View {
        Button(action: connect) {
            HStack(spacing: 8) {
                if session.isConnecting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .black))
                }
                Text(session.isConnecting ? "正在连接…" : (isAddingAccount ? "添加账号" : "连接"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.accent)
            .cornerRadius(12)
        }
        .disabled(session.isConnecting || address.isEmpty || username.isEmpty)
    }

    @ViewBuilder
    private var recentServers: some View {
        if !session.recentServers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("最近使用")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.tertiaryText)

                ForEach(session.recentServers) { server in
                    Button {
                        address = server.baseURLString
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                                Text(server.baseURLString)
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.secondaryText)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.tertiaryText)
                        }
                        .padding(12)
                        .background(Theme.surface)
                        .cornerRadius(10)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
    }

    private func connect() {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let success = await session.login(address: trimmedAddress, username: trimmedUsername, password: password)
            if success { onFinish?() }
        }
    }
}

struct InputField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var isSecure = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.accent)
                .frame(width: 22)

            if isSecure {
                SecureField(placeholder, text: $text)
                    .foregroundColor(.white)
                    .keyboardType(keyboard)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            } else {
                TextField(placeholder, text: $text)
                    .foregroundColor(.white)
                    .keyboardType(keyboard)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(Theme.surface)
        .cornerRadius(12)
        .cardStroke(12)
    }
}

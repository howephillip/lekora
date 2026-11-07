import SwiftUI

public struct WalkingSkeletonPingView: View {
    @ObservedObject public var gateway: GatewayClient
    public let instanceName: String
    public let profileName: String

    public init(gateway: GatewayClient, instanceName: String, profileName: String) {
        self.gateway = gateway
        self.instanceName = instanceName
        self.profileName = profileName
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Host Header
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 12, height: 12)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(instanceName)
                            .font(.headline)
                        Text("Active Agent: \(profileName)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()

                    Text("Seq #\(gateway.currentSeq)")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(6)
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(12)
                .padding(.horizontal)

                // Event / Message Log
                List {
                    Section(header: Text("Live Streamed Events")) {
                        if gateway.receivedMessages.isEmpty {
                            Text("No events received yet. Tap 'Send Ping' below to test live bidirectional round-trip.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(Array(gateway.receivedMessages.enumerated()), id: \.offset) { _, message in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "bubble.left.and.bubble.right.fill")
                                        .foregroundColor(.blue)
                                        .padding(.top, 2)

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(message.role.capitalized)
                                                .font(.caption)
                                                .fontWeight(.bold)
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            Text("Seq: \(message.seq)")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }

                                        Text(message.text)
                                            .font(.body)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif

                // Action Area
                VStack(spacing: 12) {
                    Button(action: {
                        Task {
                            await gateway.sendPing()
                        }
                    }) {
                        Label("Send Ping", systemImage: "paperplane.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }

                    Button("Disconnect", role: .destructive) {
                        gateway.disconnect()
                    }
                    .font(.footnote)
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            .navigationTitle("Walking Skeleton")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}

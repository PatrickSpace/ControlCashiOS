//
//  ContentView.swift
//  ControlCash
//
//  Created by Patrick Lostaunau on 27/05/26.
//

import SwiftUI
import AVFoundation
import Combine
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import GoogleSignIn

struct ContentView: View {
    @StateObject private var authViewModel = AuthViewModel()
    @StateObject private var catalogsViewModel = CatalogsViewModel()
    @StateObject private var transactionsViewModel = TransactionsViewModel()
    @State private var editorContext: TransactionEditorContext?
    @State private var transactionToDelete: Transaction?

    private var accounts: [Account] {
        catalogsViewModel.accounts
    }

    private var cards: [CreditCard] {
        catalogsViewModel.cards
    }

    private var categories: [Category] {
        catalogsViewModel.categories
    }

    private var transactions: [Transaction] {
        transactionsViewModel.transactions
    }

    private var sortedTransactions: [Transaction] {
        transactions.sorted { $0.date > $1.date }
    }

    private var monthlyIncome: Double {
        transactions
            .filter { $0.type == .income }
            .reduce(0) { $0 + $1.amount }
    }

    private var monthlyExpenses: Double {
        transactions
            .filter { $0.type.isExpense }
            .reduce(0) { $0 + $1.amount }
    }

    private var monthlyBalance: Double {
        monthlyIncome - monthlyExpenses
    }

    private var totalCardDebt: Double {
        cards.reduce(0) { partialResult, card in
            partialResult + cardDebt(card.id)
        }
    }

    private var recommendedCard: RecommendedCard? {
        var bestRecommendation: RecommendedCard?

        for card in cards where card.isActive {
            let debt = cardDebt(card.id)
            let available = max(card.creditLimit - debt, 0)

            guard available > 0 else {
                continue
            }

            let usage = card.creditLimit > 0 ? min((debt / card.creditLimit) * 100, 100) : 0
            let safeRoom = max(card.creditLimit * 0.8 - debt, 0)
            let recommendedSpend = min(available, safeRoom)
            let recommendation = RecommendedCard(
                card: card,
                available: available,
                recommendedSpend: recommendedSpend,
                usage: usage
            )

            if bestRecommendation == nil || recommendedSpend > bestRecommendation!.recommendedSpend {
                bestRecommendation = recommendation
            }
        }

        return bestRecommendation
    }

    var body: some View {
        Group {
            if authViewModel.isResolvingSession {
                SplashScreen()
            } else if authViewModel.user == nil {
                LoginScreen(authViewModel: authViewModel)
            } else {
                appTabs
            }
        }
        .onAppear {
            handleSessionChange(authViewModel.user?.uid)
        }
        .onChange(of: authViewModel.user?.uid) { _, userId in
            handleSessionChange(userId)
        }
    }

    private var appTabs: some View {
        TabView {
            homeTab
            transactionsTab
        }
        .tint(.controlAccent)
        .sheet(item: $editorContext) { context in
            TransactionEditorView(
                context: context,
                accounts: accounts,
                cards: cards,
                categories: categories,
                onSave: saveTransaction
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Eliminar transacción",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible,
            presenting: transactionToDelete
        ) { transaction in
            Button("Eliminar", role: .destructive) {
                delete(transaction)
            }

            Button("Cancelar", role: .cancel) {
                transactionToDelete = nil
            }
        } message: { transaction in
            Text("Se eliminará \(transaction.descriptionText). Esta acción no se puede deshacer.")
        }
    }

    private var homeTab: some View {
        NavigationStack {
            homeScreen
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
        }
        .tabItem {
            Label("Home", systemImage: "house")
        }
    }

    private var transactionsTab: some View {
        NavigationStack {
            transactionsScreen
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
        }
        .tabItem {
            Label("Transacciones", systemImage: "arrow.left.arrow.right")
        }
    }

    private var transactionsScreen: some View {
        TransactionsScreen(
            transactions: sortedTransactions,
            isLoading: transactionsViewModel.isLoading,
            errorMessage: transactionsViewModel.errorMessage ?? catalogsViewModel.errorMessage,
            accounts: accounts,
            cards: cards,
            categories: categories,
            onAdd: openCreateTransaction,
            onEdit: openEditTransaction,
            onDelete: confirmDeleteTransaction
        )
    }

    private var homeScreen: some View {
        ZStack {
            ControlCashBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    dashboard
                    recentTransactionsPanel
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { transactionToDelete != nil },
            set: { isPresented in
                if !isPresented {
                    transactionToDelete = nil
                }
            }
        )
    }

    private func openCreateTransaction() {
        editorContext = .create(accounts: accounts, cards: cards, categories: categories)
    }

    private func openEditTransaction(_ transaction: Transaction) {
        editorContext = .edit(transaction)
    }

    private func confirmDeleteTransaction(_ transaction: Transaction) {
        transactionToDelete = transaction
    }

    private var header: some View {
        HStack(spacing: 14) {
            RoundedIcon(systemName: "banknote", color: .controlAccent, size: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text("ControlCash")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)

                Text(authViewModel.greeting)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
            }

            Spacer()

            Button {
                authViewModel.signOut()
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.headline.weight(.semibold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.75))
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel("Cerrar sesión")

            Button {
                editorContext = .create(accounts: accounts, cards: cards, categories: categories)
            } label: {
                Image(systemName: "plus")
                    .font(.headline.weight(.bold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.controlInk)
            .background(Color.controlAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel("Nueva transacción")
        }
    }

    private var dashboard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                SummaryMetricCard(
                    title: "Ingresos",
                    value: MoneyFormatter.string(monthlyIncome),
                    systemName: "arrow.down.circle",
                    tint: .controlSuccess
                )

                SummaryMetricCard(
                    title: "Gastos",
                    value: MoneyFormatter.string(monthlyExpenses),
                    systemName: "arrow.up.circle",
                    tint: .controlDanger
                )
            }

            SummaryMetricCard(
                title: "Balance",
                value: MoneyFormatter.string(monthlyBalance),
                caption: "\(transactions.count) movimientos registrados",
                systemName: "chart.line.uptrend.xyaxis",
                tint: monthlyBalance >= 0 ? .controlSuccess : .controlDanger
            )

            creditRecommendationCard
        }
    }

    private var creditRecommendationCard: some View {
        ControlPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    RoundedIcon(systemName: "creditcard.and.123", color: .controlAccent, size: 46)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Tarjeta recomendada")
                            .font(.headline)
                            .foregroundStyle(.white)

                        Text("Puedes gastar con tarjeta")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.68))
                    }

                    Spacer()
                }

                if let recommendedCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .lastTextBaseline) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(recommendedCard.card.name)
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(.white)

                                Text(recommendedCard.card.bank)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.68))
                            }

                            Spacer()

                            Text(MoneyFormatter.string(recommendedCard.recommendedSpend))
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)
                        }

                        ProgressView(value: recommendedCard.usage, total: 100)
                            .tint(recommendedCard.usage > 70 ? .controlWarning : .controlAccent)

                        HStack {
                            Label("\(Int(recommendedCard.usage.rounded()))% usado", systemImage: "gauge.with.dots.needle.50percent")
                            Spacer()
                            Text("\(MoneyFormatter.string(recommendedCard.available)) disponible")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.72))
                    }
                } else {
                    Text("Agrega una tarjeta activa con línea de crédito para recibir una recomendación.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
        }
    }

    private var recentTransactionsPanel: some View {
        ControlPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    RoundedIcon(systemName: "arrow.left.arrow.right", color: .controlAccent, size: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Últimos movimientos")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)

                        Text("Actividad reciente de tus datos de ejemplo")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.68))
                    }

                    Spacer()
                }

                LazyVStack(spacing: 10) {
                    ForEach(sortedTransactions.prefix(3)) { transaction in
                        TransactionRowView(
                            transaction: transaction,
                            accountName: accountName(for: transaction.accountId),
                            destinationAccountName: accountName(for: transaction.destinationAccountId),
                            categoryName: categoryName(for: transaction.categoryId),
                            cardName: cardName(for: transaction.cardId)
                        )
                    }
                }
            }
        }
    }

    private func saveTransaction(_ transaction: Transaction) {
        transactionsViewModel.save(transaction)
    }

    private func delete(_ transaction: Transaction) {
        transactionsViewModel.delete(transaction)
        transactionToDelete = nil
    }

    private func handleSessionChange(_ userId: String?) {
        if let userId {
            transactionsViewModel.startListening(userId: userId)
            catalogsViewModel.startListening(userId: userId)
        } else {
            transactionsViewModel.stopListening()
            catalogsViewModel.stopListening()
        }
    }

    private func accountName(for id: String?) -> String? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }?.name
    }

    private func cardName(for id: String?) -> String? {
        guard let id else { return nil }
        return cards.first { $0.id == id }?.name
    }

    private func categoryName(for id: String?) -> String? {
        guard let id else { return nil }
        return categories.first { $0.id == id }?.name
    }

    private func cardDebt(_ cardId: String) -> Double {
        transactions.reduce(0) { debt, transaction in
            switch transaction.type {
            case .cardPurchase:
                return transaction.cardId == cardId ? debt + transaction.amount : debt
            case .cardPayment:
                return transaction.cardId == cardId ? debt - transaction.amount : debt
            case .expense:
                return transaction.paymentMethod == .credit && transaction.cardId == cardId ? debt + transaction.amount : debt
            case .income, .transfer:
                return debt
            }
        }
    }
}

private struct SplashScreen: View {
    var body: some View {
        ZStack {
            ControlCashBackground()

            VStack(spacing: 18) {
                RoundedIcon(systemName: "banknote", color: .controlAccent, size: 58)

                ProgressView()
                    .tint(.controlAccent)

                Text("Preparando ControlCash")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
    }
}

private struct LoginScreen: View {
    @ObservedObject var authViewModel: AuthViewModel

    var body: some View {
        ZStack {
            ControlCashBackground()

            VStack(spacing: 18) {
                Spacer()

                ControlPanel {
                    VStack(alignment: .leading, spacing: 20) {
                        RoundedIcon(systemName: "banknote", color: .controlAccent, size: 58)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("ControlCash")
                                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                                .foregroundStyle(.white)

                            Text("Inicia sesión para guardar tus transacciones en Firestore.")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.72))
                        }

                        Button {
                            authViewModel.signInWithGoogle()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.badge.checkmark")
                                    .font(.headline)

                                Text(authViewModel.isSigningIn ? "Conectando..." : "Continuar con Google")
                                    .font(.headline.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        }
                        .disabled(authViewModel.isSigningIn)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.controlInk)
                        .background(Color.controlAccent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                        if let errorMessage = authViewModel.errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(Color.controlDanger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Spacer()
            }
            .padding(20)
        }
    }
}

@MainActor
private final class AuthViewModel: ObservableObject {
    @Published var user: User?
    @Published var isResolvingSession = true
    @Published var isSigningIn = false
    @Published var errorMessage: String?

    private var authStateHandle: AuthStateDidChangeListenerHandle?

    var greeting: String {
        "Hola, \(displayName)"
    }

    private var displayName: String {
        user?.displayName?.nilIfEmpty ??
        user?.email?.components(separatedBy: "@").first?.nilIfEmpty ??
        "usuario"
    }

    init() {
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.user = user
                self?.isResolvingSession = false
            }
        }
    }

    deinit {
        if let authStateHandle {
            Auth.auth().removeStateDidChangeListener(authStateHandle)
        }
    }

    func signInWithGoogle() {
        guard !isSigningIn else { return }

        guard let clientID = FirebaseApp.app()?.options.clientID else {
            errorMessage = "No se encontró CLIENT_ID en GoogleService-Info.plist."
            return
        }

        guard let presentingViewController = UIApplication.shared.controlCashRootViewController else {
            errorMessage = "No se pudo abrir la ventana de inicio de sesión."
            return
        }

        isSigningIn = true
        errorMessage = nil

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.signIn(withPresenting: presentingViewController) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let authViewModel = self else { return }

                if let error {
                    authViewModel.isSigningIn = false
                    authViewModel.errorMessage = error.localizedDescription
                    return
                }

                guard
                    let googleUser = result?.user,
                    let idToken = googleUser.idToken?.tokenString
                else {
                    authViewModel.isSigningIn = false
                    authViewModel.errorMessage = "Google no devolvió un token válido."
                    return
                }

                let credential = GoogleAuthProvider.credential(
                    withIDToken: idToken,
                    accessToken: googleUser.accessToken.tokenString
                )

                Auth.auth().signIn(with: credential) { authResult, error in
                    Task { @MainActor in
                        authViewModel.isSigningIn = false

                        if let error {
                            authViewModel.errorMessage = error.localizedDescription
                            return
                        }

                        if let user = authResult?.user {
                            authViewModel.user = user
                            authViewModel.upsertUserDocument(user)
                        }
                    }
                }
            }
        }
    }

    func signOut() {
        do {
            GIDSignIn.sharedInstance.signOut()
            try Auth.auth().signOut()
            user = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func upsertUserDocument(_ user: User) {
        var payload: [String: Any] = [
            "displayName": user.displayName ?? "",
            "email": user.email ?? "",
            "updatedAt": FieldValue.serverTimestamp()
        ]

        if let photoURL = user.photoURL?.absoluteString {
            payload["photoURL"] = photoURL
        }

        Firestore.firestore()
            .collection("users")
            .document(user.uid)
            .setData(payload, merge: true)
    }
}

@MainActor
private final class TransactionsViewModel: ObservableObject {
    @Published var transactions: [Transaction] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var listener: ListenerRegistration?
    private var userId: String?

    func startListening(userId: String) {
        guard self.userId != userId else { return }

        stopListening()
        self.userId = userId
        isLoading = true
        errorMessage = nil

        listener = transactionsCollection(userId: userId)
            .order(by: "date", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isLoading = false

                    if let error {
                        self.errorMessage = error.localizedDescription
                        return
                    }

                    self.transactions = snapshot?.documents.compactMap { document in
                        Transaction(id: document.documentID, data: document.data())
                    } ?? []
                }
            }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
        userId = nil
        transactions = []
        isLoading = false
    }

    func save(_ transaction: Transaction) {
        guard let userId else {
            errorMessage = "Inicia sesión para guardar transacciones."
            return
        }

        errorMessage = nil
        let document = transactionsCollection(userId: userId).document(transaction.id)

        document.setData(transaction.firestoreData(isNew: !transactions.contains(where: { $0.id == transaction.id })), merge: true) { [weak self] error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func delete(_ transaction: Transaction) {
        guard let userId else {
            errorMessage = "Inicia sesión para borrar transacciones."
            return
        }

        errorMessage = nil

        transactionsCollection(userId: userId).document(transaction.id).delete { [weak self] error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func transactionsCollection(userId: String) -> CollectionReference {
        Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("transactions")
    }
}

@MainActor
private final class CatalogsViewModel: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var cards: [CreditCard] = []
    @Published var categories: [Category] = []
    @Published var errorMessage: String?

    private var listeners: [ListenerRegistration] = []
    private var userId: String?

    func startListening(userId: String) {
        guard self.userId != userId else { return }

        stopListening()
        self.userId = userId
        errorMessage = nil

        let userDocument = Firestore.firestore().collection("users").document(userId)

        listeners = [
            userDocument.collection("accounts").addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }

                    if let error {
                        self.errorMessage = error.localizedDescription
                        return
                    }

                    self.accounts = snapshot?.documents
                        .compactMap { Account(id: $0.documentID, data: $0.data()) }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } ?? []
                }
            },
            userDocument.collection("cards").addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }

                    if let error {
                        self.errorMessage = error.localizedDescription
                        return
                    }

                    self.cards = snapshot?.documents
                        .compactMap { CreditCard(id: $0.documentID, data: $0.data()) }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } ?? []
                }
            },
            userDocument.collection("categories").addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }

                    if let error {
                        self.errorMessage = error.localizedDescription
                        return
                    }

                    self.categories = snapshot?.documents
                        .compactMap { Category(id: $0.documentID, data: $0.data()) }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } ?? []
                }
            }
        ]
    }

    func stopListening() {
        listeners.forEach { $0.remove() }
        listeners = []
        userId = nil
        accounts = []
        cards = []
        categories = []
    }
}

private extension UIApplication {
    var controlCashRootViewController: UIViewController? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController?
            .topMostViewController
    }
}

private extension UIViewController {
    var topMostViewController: UIViewController {
        if let presentedViewController {
            return presentedViewController.topMostViewController
        }

        if let navigationController = self as? UINavigationController {
            return navigationController.visibleViewController?.topMostViewController ?? navigationController
        }

        if let tabBarController = self as? UITabBarController {
            return tabBarController.selectedViewController?.topMostViewController ?? tabBarController
        }

        return self
    }
}

private struct ControlCashBackground: View {
    var body: some View {
        LinearGradient(
            colors: [.controlBackgroundStart, .controlBackgroundEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color.controlAccent.opacity(0.18))
                .frame(width: 280, height: 280)
                .blur(radius: 52)
                .offset(x: 88, y: -112)
        }
        .ignoresSafeArea()
    }
}

private struct ControlPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .background(Color.controlPanel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.controlAccent.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.24), radius: 18, x: 0, y: 12)
    }
}

private struct SummaryMetricCard: View {
    let title: String
    let value: String
    var caption: String?
    let systemName: String
    let tint: Color

    var body: some View {
        ControlPanel {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.68))

                    Text(value)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    if let caption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.58))
                    }
                }

                Spacer(minLength: 6)
                RoundedIcon(systemName: systemName, color: tint, size: 40)
            }
        }
    }
}

private struct TransactionsScreen: View {
    let transactions: [Transaction]
    let isLoading: Bool
    let errorMessage: String?
    let accounts: [Account]
    let cards: [CreditCard]
    let categories: [Category]
    let onAdd: () -> Void
    let onEdit: (Transaction) -> Void
    let onDelete: (Transaction) -> Void

    @State private var selectedAccountId = ""
    @State private var selectedPaymentMethod = ""
    @State private var selectedCardId = ""
    @State private var selectedCategoryId = ""
    @State private var searchText = ""

    private var hasActiveFilters: Bool {
        !selectedAccountId.isEmpty ||
        !selectedPaymentMethod.isEmpty ||
        !selectedCardId.isEmpty ||
        !selectedCategoryId.isEmpty ||
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredTransactions: [Transaction] {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return transactions.filter { transaction in
            let matchesAccount = selectedAccountId.isEmpty ||
                transaction.accountId == selectedAccountId ||
                transaction.destinationAccountId == selectedAccountId

            let matchesPaymentMethod = selectedPaymentMethod.isEmpty ||
                (transaction.type == .expense && transaction.paymentMethod?.rawValue == selectedPaymentMethod)

            let matchesCard = selectedCardId.isEmpty || transaction.cardId == selectedCardId
            let matchesCategory = selectedCategoryId.isEmpty || transaction.categoryId == selectedCategoryId
            let matchesDescription = normalizedSearch.isEmpty ||
                transaction.descriptionText.localizedCaseInsensitiveContains(normalizedSearch)

            return matchesAccount && matchesPaymentMethod && matchesCard && matchesCategory && matchesDescription
        }
    }

    var body: some View {
        ZStack {
            ControlCashBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    voiceTransactionPanel
                    statusPanel
                    filtersPanel
                    resultsPanel
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var voiceTransactionPanel: some View {
        VoiceTransactionPanel()
    }

    @ViewBuilder
    private var statusPanel: some View {
        if isLoading || errorMessage != nil {
            ControlPanel {
                VStack(alignment: .leading, spacing: 10) {
                    if isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(.controlAccent)

                            Text("Cargando transacciones...")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(Color.controlDanger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            RoundedIcon(systemName: "arrow.left.arrow.right", color: .controlAccent, size: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text("Transacciones")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)

                Text("\(filteredTransactions.count) de \(transactions.count) movimientos")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
            }

            Spacer()

            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.headline.weight(.bold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.controlInk)
            .background(Color.controlAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel("Nueva transacción")
        }
    }

    private var filtersPanel: some View {
        ControlPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(Color.controlAccent)

                    Text("Filtros")
                        .font(.headline)
                        .foregroundStyle(.white)

                    Spacer()

                    if hasActiveFilters {
                        Button("Limpiar") {
                            clearFilters()
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.controlAccent)
                    }
                }

                TextField("Buscar descripción", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .foregroundStyle(.white)
                    .background(Color.controlField, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .trailing) {
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white.opacity(0.58))
                                    .padding(.trailing, 12)
                            }
                        }
                    }

                VStack(spacing: 10) {
                    FilterPicker(
                        title: "Cuenta",
                        systemName: "wallet.pass",
                        selection: $selectedAccountId,
                        options: accounts.map { FilterOption(id: $0.id, title: accountOptionTitle($0)) }
                    )

                    FilterPicker(
                        title: "Tipo de gasto",
                        systemName: "creditcard",
                        selection: $selectedPaymentMethod,
                        options: PaymentMethod.allCases.map { FilterOption(id: $0.rawValue, title: $0.label) }
                    )

                    FilterPicker(
                        title: "Tarjeta",
                        systemName: "creditcard.viewfinder",
                        selection: $selectedCardId,
                        options: cards.map { FilterOption(id: $0.id, title: cardOptionTitle($0)) }
                    )

                    FilterPicker(
                        title: "Categoría",
                        systemName: "tag",
                        selection: $selectedCategoryId,
                        options: categories.map { FilterOption(id: $0.id, title: categoryOptionTitle($0)) }
                    )
                }

                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(.controlAccent)

                        Text("Cargando transacciones...")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.controlDanger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var resultsPanel: some View {
        ControlPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    RoundedIcon(systemName: "list.bullet.rectangle", color: .controlAccent, size: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Resultados")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)

                        Text(hasActiveFilters ? "Coincidencias para los filtros seleccionados" : "Todas las transacciones")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.68))
                    }

                    Spacer()
                }

                if filteredTransactions.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(Color.controlAccent)

                        Text("No hay transacciones para estos filtros.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.72))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredTransactions) { transaction in
                            TransactionRowView(
                                transaction: transaction,
                                accountName: accountName(for: transaction.accountId),
                                destinationAccountName: accountName(for: transaction.destinationAccountId),
                                categoryName: categoryName(for: transaction.categoryId),
                                cardName: cardName(for: transaction.cardId),
                                onEdit: {
                                    onEdit(transaction)
                                },
                                onDelete: {
                                    onDelete(transaction)
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private func clearFilters() {
        selectedAccountId = ""
        selectedPaymentMethod = ""
        selectedCardId = ""
        selectedCategoryId = ""
        searchText = ""
    }

    private func accountName(for id: String?) -> String? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }?.name
    }

    private func cardName(for id: String?) -> String? {
        guard let id else { return nil }
        return cards.first { $0.id == id }?.name
    }

    private func categoryName(for id: String?) -> String? {
        guard let id else { return nil }
        return categories.first { $0.id == id }?.name
    }

    private func accountOptionTitle(_ account: Account) -> String {
        account.isActive ? account.name : "\(account.name) - Inactiva"
    }

    private func cardOptionTitle(_ card: CreditCard) -> String {
        let title = "\(card.name) - \(card.bank)"
        return card.isActive ? title : "\(title) - Inactiva"
    }

    private func categoryOptionTitle(_ category: Category) -> String {
        let title = "\(category.name) - \(category.type.label)"
        return category.isActive ? title : "\(title) - Inactiva"
    }
}

private struct FilterOption: Identifiable {
    let id: String
    let title: String
}

private struct FilterPicker: View {
    let title: String
    let systemName: String
    @Binding var selection: String
    let options: [FilterOption]

    var body: some View {
        Menu {
            Button("Todos") {
                selection = ""
            }

            ForEach(options) { option in
                Button(option.title) {
                    selection = option.id
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemName)
                    .foregroundStyle(Color.controlAccent)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.58))

                    Text(selectedTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(12)
            .background(Color.controlField, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var selectedTitle: String {
        guard !selection.isEmpty else {
            return "Todos"
        }

        return options.first { $0.id == selection }?.title ?? "Todos"
    }
}

private struct VoiceTransactionPanel: View {
    @StateObject private var viewModel = VoiceTransactionViewModel()

    var body: some View {
        ControlPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    RoundedIcon(
                        systemName: viewModel.isRecording ? "waveform" : "mic",
                        color: viewModel.isRecording ? .controlDanger : .controlAccent,
                        size: 42
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Crear con audio")
                            .font(.headline)
                            .foregroundStyle(.white)

                        Text(viewModel.statusText)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.68))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }

                HStack(spacing: 10) {
                    Button {
                        viewModel.toggleRecording()
                    } label: {
                        Label(
                            viewModel.primaryButtonTitle,
                            systemImage: viewModel.isRecording ? "stop.fill" : "mic.fill"
                        )
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                    }
                    .disabled(viewModel.isProcessing)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.controlInk)
                    .background(
                        (viewModel.isRecording ? Color.controlDanger : Color.controlAccent),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )

                    if viewModel.isProcessing {
                        ProgressView()
                            .tint(.controlAccent)
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.controlDanger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let successMessage = viewModel.successMessage {
                    Text(successMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.controlSuccess)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

@MainActor
private final class VoiceTransactionViewModel: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var errorMessage: String?
    @Published var successMessage: String?

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    var primaryButtonTitle: String {
        if isProcessing {
            return "Interpretando"
        }

        return isRecording ? "Detener y crear" : "Grabar audio"
    }

    var statusText: String {
        if isProcessing {
            return "La IA está interpretando el audio y creará la transacción."
        }

        if isRecording {
            return "Di algo como: gasté 35 soles en taxi con BCP hoy."
        }

        return "Dicta una transacción y se guardará automáticamente en Firestore."
    }

    func toggleRecording() {
        if isRecording {
            stopRecordingAndSend()
        } else {
            requestPermissionAndRecord()
        }
    }

    private func requestPermissionAndRecord() {
        errorMessage = nil
        successMessage = nil

        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if granted {
                    self.startRecording()
                } else {
                    self.errorMessage = "Permite acceso al micrófono para grabar transacciones."
                }
            }
        }
    }

    private func startRecording() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-transaction-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.record()
            recordingURL = url
            isRecording = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopRecordingAndSend() {
        recorder?.stop()
        recorder = nil
        isRecording = false

        guard let recordingURL else {
            errorMessage = "No se encontró el audio grabado."
            return
        }

        sendAudio(recordingURL)
    }

    private func sendAudio(_ url: URL) {
        isProcessing = true
        errorMessage = nil
        successMessage = nil

        do {
            let audioData = try Data(contentsOf: url)
            let payload: [String: Any] = [
                "audioBase64": audioData.base64EncodedString(),
                "mimeType": "audio/mp4"
            ]

            Functions.functions(region: "us-central1")
                .httpsCallable("createTransactionFromAudio")
                .call(payload) { [weak self] result, error in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.isProcessing = false

                        try? FileManager.default.removeItem(at: url)

                        if let error {
                            self.errorMessage = error.localizedDescription
                            return
                        }

                        let response = result?.data as? [String: Any]
                        let description = response?["description"] as? String ?? "Transacción creada"

                        self.successMessage = "\(description) fue guardada."
                    }
                }
        } catch {
            isProcessing = false
            errorMessage = error.localizedDescription
        }
    }
}

private struct TransactionRowView: View {
    let transaction: Transaction
    let accountName: String?
    let destinationAccountName: String?
    let categoryName: String?
    let cardName: String?
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    private var detail: String {
        switch transaction.type {
        case .transfer:
            return "\(accountName ?? "Origen") -> \(destinationAccountName ?? "Destino")"
        case .cardPayment:
            return "\(accountName ?? "Cuenta") -> \(cardName ?? "Tarjeta")"
        case .cardPurchase:
            return cardName ?? "Tarjeta"
        case .income, .expense:
            return categoryName ?? accountName ?? transaction.paymentMethod?.label ?? "Movimiento"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedIcon(systemName: transaction.type.iconName, color: transaction.type.tint, size: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.descriptionText)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("\(transaction.formattedDate) - \(transaction.type.label) - \(detail)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                Text(transaction.signedAmount)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(transaction.type.amountColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if let onEdit, let onDelete {
                    HStack(spacing: 2) {
                        Button(action: onEdit) {
                            Image(systemName: "pencil")
                                .frame(width: 28, height: 28)
                        }
                        .accessibilityLabel("Editar transacción")

                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "trash")
                                .frame(width: 28, height: 28)
                        }
                        .accessibilityLabel("Eliminar transacción")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.72))
                }
            }
        }
        .padding(12)
        .background(Color.controlListItem, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct RoundedIcon: View {
    let systemName: String
    let color: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct TransactionEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let context: TransactionEditorContext
    let accounts: [Account]
    let cards: [CreditCard]
    let categories: [Category]
    let onSave: (Transaction) -> Void

    @State private var type: TransactionType
    @State private var amountText: String
    @State private var date: Date
    @State private var description: String
    @State private var categoryId: String
    @State private var accountId: String
    @State private var destinationAccountId: String
    @State private var cardId: String
    @State private var paymentMethod: PaymentMethod
    @State private var validationMessage: String?

    init(
        context: TransactionEditorContext,
        accounts: [Account],
        cards: [CreditCard],
        categories: [Category],
        onSave: @escaping (Transaction) -> Void
    ) {
        self.context = context
        self.accounts = accounts
        self.cards = cards
        self.categories = categories
        self.onSave = onSave

        let transaction = context.transaction
        _type = State(initialValue: transaction.type)
        _amountText = State(initialValue: transaction.amount.cleanString)
        _date = State(initialValue: DateFormatter.controlCashDate.date(from: transaction.date) ?? Date())
        _description = State(initialValue: transaction.description ?? "")
        _categoryId = State(initialValue: transaction.categoryId ?? "")
        _accountId = State(initialValue: transaction.accountId ?? accounts.first?.id ?? "")
        _destinationAccountId = State(initialValue: transaction.destinationAccountId ?? accounts.dropFirst().first?.id ?? accounts.first?.id ?? "")
        _cardId = State(initialValue: transaction.cardId ?? cards.first?.id ?? "")
        _paymentMethod = State(initialValue: transaction.paymentMethod ?? .debit)
    }

    private var title: String {
        context.isNew ? "Nueva transacción" : "Editar transacción"
    }

    private var compatibleCategories: [Category] {
        categories.filter { category in
            guard category.isActive else { return false }

            switch type {
            case .income:
                return category.type == .income
            case .expense, .cardPurchase:
                return category.type == .expense
            case .transfer, .cardPayment:
                return false
            }
        }
    }

    private var usesAccount: Bool {
        type == .income ||
        type == .transfer ||
        type == .cardPayment ||
        (type == .expense && [.cash, .debit].contains(paymentMethod))
    }

    private var usesDestinationAccount: Bool {
        type == .transfer
    }

    private var usesCard: Bool {
        type == .cardPayment ||
        type == .cardPurchase ||
        (type == .expense && paymentMethod == .credit)
    }

    private var usesCategory: Bool {
        type == .income || type == .expense || type == .cardPurchase
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Movimiento") {
                    Picker("Tipo", selection: $type) {
                        ForEach(TransactionType.editorCases) { type in
                            Text(type.label).tag(type)
                        }
                    }

                    DatePicker("Fecha", selection: $date, displayedComponents: .date)

                    TextField("Monto", text: $amountText)
                        .keyboardType(.decimalPad)

                    TextField("Descripción", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }

                if type == .expense {
                    Section("Método de pago") {
                        Picker("Método", selection: $paymentMethod) {
                            ForEach(PaymentMethod.allCases) { method in
                                Text(method.label).tag(method)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("Detalle") {
                    if usesCategory {
                        Picker("Categoría", selection: $categoryId) {
                            Text("Sin categoría").tag("")
                            ForEach(compatibleCategories) { category in
                                Text(category.name).tag(category.id)
                            }
                        }
                    }

                    if usesAccount {
                        Picker(accountPickerTitle, selection: $accountId) {
                            ForEach(activeAccounts) { account in
                                Text(account.name).tag(account.id)
                            }
                        }
                    }

                    if usesDestinationAccount {
                        Picker("Cuenta destino", selection: $destinationAccountId) {
                            ForEach(activeAccounts) { account in
                                Text(account.name).tag(account.id)
                            }
                        }
                    }

                    if usesCard {
                        Picker("Tarjeta", selection: $cardId) {
                            ForEach(activeCards) { card in
                                Text("\(card.name) - \(card.bank)").tag(card.id)
                            }
                        }
                    }
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.controlBackgroundStart)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        handleSave()
                    }
                }
            }
            .onChange(of: type) {
                normalizeDependentFields()
            }
            .onChange(of: paymentMethod) {
                normalizeDependentFields()
            }
        }
    }

    private var accountPickerTitle: String {
        switch type {
        case .transfer:
            return "Cuenta origen"
        case .cardPayment:
            return "Cuenta de cargo"
        case .expense:
            return "Cuenta a cargo"
        case .income, .cardPurchase:
            return "Cuenta"
        }
    }

    private var activeAccounts: [Account] {
        accounts.filter(\.isActive)
    }

    private var activeCards: [CreditCard] {
        cards.filter(\.isActive)
    }

    private func handleSave() {
        guard let amount = Double(amountText.replacingOccurrences(of: ",", with: ".")), amount > 0 else {
            validationMessage = "Ingresa un monto mayor a cero."
            return
        }

        guard description.count <= 180 else {
            validationMessage = "La descripción debe tener 180 caracteres o menos."
            return
        }

        if usesDestinationAccount && accountId == destinationAccountId {
            validationMessage = "La cuenta origen y destino deben ser distintas."
            return
        }

        if usesAccount && accountId.isEmpty {
            validationMessage = "Selecciona una cuenta."
            return
        }

        if usesCard && cardId.isEmpty {
            validationMessage = "Selecciona una tarjeta."
            return
        }

        let normalizedType = type == .cardPurchase ? .expense : type
        let transaction = Transaction(
            id: context.transaction.id,
            type: normalizedType,
            amount: amount,
            date: DateFormatter.controlCashDate.string(from: date),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            categoryId: usesCategory ? categoryId.nilIfEmpty : nil,
            accountId: usesAccount ? accountId.nilIfEmpty : nil,
            destinationAccountId: usesDestinationAccount ? destinationAccountId.nilIfEmpty : nil,
            cardId: usesCard ? cardId.nilIfEmpty : nil,
            paymentMethod: normalizedType == .expense ? paymentMethod : nil
        )

        onSave(transaction)
        dismiss()
    }

    private func normalizeDependentFields() {
        validationMessage = nil

        if !compatibleCategories.contains(where: { $0.id == categoryId }) {
            categoryId = compatibleCategories.first?.id ?? ""
        }

        if usesAccount && !activeAccounts.contains(where: { $0.id == accountId }) {
            accountId = activeAccounts.first?.id ?? ""
        }

        if usesDestinationAccount && !activeAccounts.contains(where: { $0.id == destinationAccountId }) {
            destinationAccountId = activeAccounts.first(where: { $0.id != accountId })?.id ?? ""
        }

        if usesCard && !activeCards.contains(where: { $0.id == cardId }) {
            cardId = activeCards.first?.id ?? ""
        }

        if usesDestinationAccount && destinationAccountId == accountId {
            destinationAccountId = activeAccounts.first(where: { $0.id != accountId })?.id ?? ""
        }
    }
}

private struct TransactionEditorContext: Identifiable {
    let id: String
    let isNew: Bool
    let transaction: Transaction

    static func create(accounts: [Account], cards: [CreditCard], categories: [Category]) -> TransactionEditorContext {
        let activeExpenseCategory = categories.first { $0.isActive && $0.type == .expense }
        let activeAccount = accounts.first { $0.isActive }

        return TransactionEditorContext(
            id: UUID().uuidString,
            isNew: true,
            transaction: Transaction(
                id: UUID().uuidString,
                type: .expense,
                amount: 0,
                date: DateFormatter.controlCashDate.string(from: Date()),
                description: nil,
                categoryId: activeExpenseCategory?.id,
                accountId: activeAccount?.id,
                destinationAccountId: nil,
                cardId: nil,
                paymentMethod: .debit
            )
        )
    }

    static func edit(_ transaction: Transaction) -> TransactionEditorContext {
        TransactionEditorContext(id: transaction.id, isNew: false, transaction: transaction)
    }
}

private struct RecommendedCard {
    let card: CreditCard
    let available: Double
    let recommendedSpend: Double
    let usage: Double
}

private struct Account: Identifiable {
    let id: String
    let name: String
    let type: AccountType
    let isActive: Bool

    init?(id: String, data: [String: Any]) {
        guard let name = data["name"] as? String else {
            return nil
        }

        self.id = id
        self.name = name
        self.type = AccountType(rawValue: data["type"] as? String ?? "") ?? .bank
        self.isActive = data["isActive"] as? Bool ?? true
    }
}

private enum AccountType: String {
    case cash
    case bank
    case savings
    case credit
    case investments
}

private struct CreditCard: Identifiable {
    let id: String
    let name: String
    let bank: String
    let creditLimit: Double
    let isActive: Bool

    init?(id: String, data: [String: Any]) {
        guard let name = data["name"] as? String else {
            return nil
        }

        self.id = id
        self.name = name
        self.bank = data["bank"] as? String ?? ""
        self.creditLimit = Transaction.amountValue(from: data["creditLimit"]) ?? 0
        self.isActive = data["isActive"] as? Bool ?? true
    }
}

private struct Category: Identifiable {
    let id: String
    let name: String
    let type: CategoryType
    let isActive: Bool

    init?(id: String, data: [String: Any]) {
        guard let name = data["name"] as? String else {
            return nil
        }

        self.id = id
        self.name = name
        self.type = CategoryType(rawValue: data["type"] as? String ?? "") ?? .expense
        self.isActive = data["isActive"] as? Bool ?? true
    }
}

private enum CategoryType: String {
    case income
    case expense

    var label: String {
        switch self {
        case .income:
            return "Ingreso"
        case .expense:
            return "Gasto"
        }
    }
}

private struct Transaction: Identifiable, Equatable {
    let id: String
    var type: TransactionType
    var amount: Double
    var date: String
    var description: String?
    var categoryId: String?
    var accountId: String?
    var destinationAccountId: String?
    var cardId: String?
    var paymentMethod: PaymentMethod?

    init(
        id: String,
        type: TransactionType,
        amount: Double,
        date: String,
        description: String?,
        categoryId: String?,
        accountId: String?,
        destinationAccountId: String?,
        cardId: String?,
        paymentMethod: PaymentMethod?
    ) {
        self.id = id
        self.type = type
        self.amount = amount
        self.date = date
        self.description = description
        self.categoryId = categoryId
        self.accountId = accountId
        self.destinationAccountId = destinationAccountId
        self.cardId = cardId
        self.paymentMethod = paymentMethod
    }

    init?(id: String, data: [String: Any]) {
        guard
            let typeValue = data["type"] as? String,
            let type = TransactionType(firestoreValue: typeValue),
            let amount = Transaction.amountValue(from: data["amount"]),
            let date = data["date"] as? String
        else {
            return nil
        }

        self.id = id
        self.type = type
        self.amount = amount
        self.date = date
        self.description = data["description"] as? String
        self.categoryId = data["categoryId"] as? String
        self.accountId = data["accountId"] as? String
        self.destinationAccountId = data["destinationAccountId"] as? String
        self.cardId = data["cardId"] as? String

        if let paymentMethodValue = data["paymentMethod"] as? String {
            self.paymentMethod = PaymentMethod(rawValue: paymentMethodValue)
        } else {
            self.paymentMethod = nil
        }
    }

    static func amountValue(from value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }

        if let value = value as? Int {
            return Double(value)
        }

        if let value = value as? NSNumber {
            return value.doubleValue
        }

        return nil
    }

    var descriptionText: String {
        description?.nilIfEmpty ?? type.label
    }

    var formattedDate: String {
        guard let date = DateFormatter.controlCashDate.date(from: date) else {
            return self.date
        }

        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    var signedAmount: String {
        let prefix = type == .income ? "+" : type == .transfer ? "" : "-"
        return "\(prefix)\(MoneyFormatter.string(amount))"
    }

    func firestoreData(isNew: Bool) -> [String: Any] {
        var data: [String: Any] = [
            "id": id,
            "type": type.rawValue,
            "amount": amount,
            "date": date,
            "updatedAt": FieldValue.serverTimestamp()
        ]

        if isNew {
            data["createdAt"] = FieldValue.serverTimestamp()
        }

        data["description"] = description ?? FieldValue.delete()
        data["categoryId"] = categoryId ?? FieldValue.delete()
        data["accountId"] = accountId ?? FieldValue.delete()
        data["destinationAccountId"] = destinationAccountId ?? FieldValue.delete()
        data["cardId"] = cardId ?? FieldValue.delete()
        data["paymentMethod"] = paymentMethod?.rawValue ?? FieldValue.delete()

        return data
    }


    static let sampleTransactions = [
        Transaction(
            id: "t1",
            type: .income,
            amount: 7200,
            date: "2026-05-25",
            description: "Sueldo mayo",
            categoryId: "salary",
            accountId: "bcp",
            destinationAccountId: nil,
            cardId: nil,
            paymentMethod: nil
        ),
        Transaction(
            id: "t2",
            type: .expense,
            amount: 164.50,
            date: "2026-05-26",
            description: "Supermercado",
            categoryId: "food",
            accountId: nil,
            destinationAccountId: nil,
            cardId: "visa-bcp",
            paymentMethod: .credit
        ),
        Transaction(
            id: "t3",
            type: .expense,
            amount: 42,
            date: "2026-05-24",
            description: "Taxi",
            categoryId: "transport",
            accountId: "bcp",
            destinationAccountId: nil,
            cardId: nil,
            paymentMethod: .debit
        ),
        Transaction(
            id: "t4",
            type: .transfer,
            amount: 900,
            date: "2026-05-22",
            description: "Separar ahorros",
            categoryId: nil,
            accountId: "bcp",
            destinationAccountId: "bbva",
            cardId: nil,
            paymentMethod: nil
        ),
        Transaction(
            id: "t5",
            type: .cardPayment,
            amount: 350,
            date: "2026-05-20",
            description: "Pago Visa",
            categoryId: nil,
            accountId: "bcp",
            destinationAccountId: nil,
            cardId: "visa-bcp",
            paymentMethod: nil
        )
    ]
}

private enum TransactionType: String, CaseIterable, Identifiable {
    case income
    case expense
    case transfer
    case cardPurchase = "card_purchase"
    case cardPayment = "card_payment"

    var id: String { rawValue }

    static let editorCases: [TransactionType] = [.income, .expense, .transfer, .cardPayment]

    init?(firestoreValue: String) {
        switch firestoreValue {
        case "cardPurchase":
            self = .cardPurchase
        case "cardPayment":
            self = .cardPayment
        default:
            self.init(rawValue: firestoreValue)
        }
    }

    var label: String {
        switch self {
        case .income:
            return "Ingreso"
        case .expense:
            return "Gasto"
        case .transfer:
            return "Transferencia"
        case .cardPurchase:
            return "Compra tarjeta"
        case .cardPayment:
            return "Pago tarjeta"
        }
    }

    var isExpense: Bool {
        self == .expense || self == .cardPurchase
    }

    var iconName: String {
        switch self {
        case .income:
            return "arrow.down.circle"
        case .expense:
            return "arrow.up.circle"
        case .transfer:
            return "arrow.left.arrow.right"
        case .cardPurchase:
            return "creditcard"
        case .cardPayment:
            return "creditcard.trianglebadge.exclamationmark"
        }
    }

    var tint: Color {
        switch self {
        case .income:
            return .controlSuccess
        case .expense, .cardPurchase:
            return .controlDanger
        case .transfer:
            return .controlAccent
        case .cardPayment:
            return .controlWarning
        }
    }

    var amountColor: Color {
        switch self {
        case .income:
            return .controlSuccess
        case .expense, .cardPurchase, .cardPayment:
            return .controlDanger
        case .transfer:
            return .white.opacity(0.86)
        }
    }
}

private enum PaymentMethod: String, CaseIterable, Identifiable {
    case cash
    case debit
    case credit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cash:
            return "Efectivo"
        case .debit:
            return "Débito"
        case .credit:
            return "Crédito"
        }
    }
}

private enum MoneyFormatter {
    static func string(_ value: Double) -> String {
        "S/. \(String(format: "%.2f", value))"
    }
}

private extension DateFormatter {
    static let controlCashDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private extension Double {
    var cleanString: String {
        truncatingRemainder(dividingBy: 1) == 0 ? String(Int(self)) : String(self)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Color {
    static let controlAccent = Color(red: 0.05, green: 0.70, blue: 0.74)
    static let controlBackgroundStart = Color(red: 0.13, green: 0.16, blue: 0.20)
    static let controlBackgroundEnd = Color(red: 0.25, green: 0.33, blue: 0.46)
    static let controlDanger = Color(red: 1.00, green: 0.40, blue: 0.45)
    static let controlField = Color(red: 0.32, green: 0.40, blue: 0.52).opacity(0.48)
    static let controlInk = Color(red: 0.09, green: 0.13, blue: 0.16)
    static let controlListItem = Color(red: 0.28, green: 0.36, blue: 0.48).opacity(0.62)
    static let controlPanel = Color(red: 0.18, green: 0.23, blue: 0.30).opacity(0.80)
    static let controlSuccess = Color(red: 0.26, green: 0.84, blue: 0.56)
    static let controlWarning = Color(red: 1.00, green: 0.72, blue: 0.25)
}

#Preview {
    ContentView()
}

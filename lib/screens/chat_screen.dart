import 'package:flutter/material.dart';
import 'package:flutter_gen_ai_chat_ui/flutter_gen_ai_chat_ui.dart';

import '../models/app_config.dart';
import '../services/chat_service.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  // ── Package objects ─────────────────────────────────────────
  final _controller = ChatMessagesController();

  final _currentUser = const ChatUser(
    id: 'user',
    firstName: 'You',
  );

  final _aiUser = const ChatUser(
    id: 'ai',
    firstName: 'Assistant',
  );

  // ── Services ────────────────────────────────────────────────
  late final ChatService _chatService;

  // ── State ───────────────────────────────────────────────────
  bool _isLoading = false;
  bool _isStreaming = false;

  // Conversation history sent to backend for context
  final List<Map<String, dynamic>> _history = [];

  @override
  void initState() {
    super.initState();
    _chatService = ChatService(
      baseUrl: AppConfig.baseUrl,
      authToken: AppConfig.authToken,
    );
  }

  @override
  void dispose() {
    _chatService.dispose();
    super.dispose();
  }

  // ── Core streaming handler ──────────────────────────────────
  Future<void> _handleSendMessage(ChatMessage userMessage) async {
    // Prevent sending while already streaming
    if (_isStreaming) return;

    // 1. Add user message to chat UI
    _controller.addMessage(userMessage);

    // 2. Save to history for context
    _history.add({'role': 'user', 'content': userMessage.text});

    // 3. Show loading / typing indicator
    setState(() {
      _isLoading = true;
      _isStreaming = true;
    });

    // 4. Create empty AI message placeholder
    //    It appears immediately as an empty bubble
    ChatMessage aiMessage = ChatMessage(
      text: '',
      user: _aiUser,
      createdAt: DateTime.now(),
      // isMarkdown: true — tells the package to render markdown
    );
    _controller.addMessage(aiMessage);

    // 5. Accumulate the full response
    String accumulated = '';

    try {
      // 6. Start streaming from backend
      final stream = _chatService.sendMessage(
        message: userMessage.text,
        history: List.from(_history),
      );

      // 7. On each delta: append + update the message
      await for (final delta in stream) {
        accumulated += delta;

        // updateMessage() → package detects new text → animates new words
        aiMessage = aiMessage.copyWith(text: accumulated);
        _controller.updateMessage(aiMessage);
      }

      // 8. Save AI response to history
      if (accumulated.isNotEmpty) {
        _history.add({'role': 'assistant', 'content': accumulated});
      }

    } on ChatException catch (e) {
      _setError(aiMessage, accumulated, e.message);

    } catch (e) {
      _setError(aiMessage, accumulated, e.toString());

    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isStreaming = false;
        });
      }
    }
  }

  // ── Error helper ────────────────────────────────────────────
  void _setError(ChatMessage msg, String accumulated, String error) {
    final text = accumulated.isEmpty
        ? '⚠️ $error'
        : '$accumulated\n\n⚠️ $error';

    _controller.updateMessage(msg.copyWith(text: text));
  }

  // ── Build ───────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Meeting Assistant'),
        actions: [
          // Show a stop indicator while streaming
          if (_isStreaming)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: AiChatWidget(
        // ── Required ──────────────────────────────────────────
        currentUser: _currentUser,
        aiUser: _aiUser,
        controller: _controller,
        onSendMessage: _handleSendMessage,

        // ── Loading / typing indicator ─────────────────────────
        loadingConfig: LoadingConfig(isLoading: _isLoading),

        // ── Streaming animation ────────────────────────────────
        enableMarkdownStreaming: true,
        streamingWordByWord: AppConfig.streamingWordByWord,
        streamingDuration: const Duration(
          milliseconds: AppConfig.streamingWordDelayMs,
        ),

        // ── Welcome screen ─────────────────────────────────────
        welcomeMessageConfig: const WelcomeMessageConfig(
          title: 'Meeting Assistant',
          questionsSectionTitle: 'Try asking:',
        ),
        exampleQuestions: const [
          ExampleQuestion(question: 'Summarize last week\'s meetings'),
          ExampleQuestion(question: 'What decisions were made on Tuesday?'),
          ExampleQuestion(question: 'Show me the action items from today'),
          ExampleQuestion(question: 'Who attended the budget meeting?'),
        ],

        // ── Input field ────────────────────────────────────────
        inputOptions: const InputOptions(
          decoration: InputDecoration(
            hintText: 'Ask about meetings or documents...',
          ),
          sendOnEnter: true,
          textInputAction: TextInputAction.send,
        ),

        // ── Layout ─────────────────────────────────────────────
        maxWidth: 800,
          ),
        ),
      ),
    );
  }
}

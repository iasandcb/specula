package com.ias.specula

import android.os.Bundle
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.*
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.viewmodel.compose.viewModel

class MainActivity : ComponentActivity() {
    private val session: SessionModel by viewModels()
    private val switcherDismissKeys = mutableSetOf<Int>()

    override fun onStop() {
        session.commandTab.release()
        super.onStop()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val dismissKey = event.keyCode == KeyEvent.KEYCODE_ENTER ||
            event.keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER || event.keyCode == KeyEvent.KEYCODE_ESCAPE
        if (event.action == KeyEvent.ACTION_DOWN && dismissKey && session.commandTab.held) {
            session.commandTab.release()
            switcherDismissKeys.add(event.keyCode)
        }
        // Consume both halves so Enter cannot reactivate a focused session button,
        // or reach the selected Mac app with no matching key-down.
        if (event.keyCode in switcherDismissKeys) {
            if (event.action == KeyEvent.ACTION_UP) switcherDismissKeys.remove(event.keyCode)
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { MaterialTheme { Surface(Modifier.fillMaxSize()) { Specula() } } }
    }
}

@Composable
private fun Specula(model: SessionModel = viewModel()) {
    val activity = LocalActivity.current ?: return
    DisposableEffect(model.connected) {
        val controller =
            WindowCompat.getInsetsController(activity.window, activity.window.decorView)
        if (model.connected) {
            controller.systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsetsCompat.Type.systemBars())
        }
        onDispose { controller.show(WindowInsetsCompat.Type.systemBars()) }
    }
    var surface by remember { mutableStateOf<RemoteSurface?>(null) }
    var keyboard by remember { mutableStateOf(false) }
    BackHandler(model.connected || model.connecting) {
        if (keyboard) {
            keyboard = false
            surface?.showKeyboard(false)
        } else model.disconnect()
    }
    Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding()) {
        if (model.connected) {
            Box(Modifier.weight(1f).fillMaxWidth()) {
                RemoteScreen(model) { surface = it }
                SessionControls(
                    model = model,
                    onKeyboard = {
                        keyboard = !keyboard
                        surface?.showKeyboard(keyboard)
                    },
                    hideKeyboard = {
                        keyboard = false
                        surface?.showKeyboard(false)
                    },
                )
            }
        } else {
            Column(
                Modifier.weight(1f)
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text("스페큘라", style = MaterialTheme.typography.headlineLarge)
                Text("맥 화면 공유", fontSize = 22.sp)
                OutlinedTextField(
                    value = model.host,
                    onValueChange = { model.host = it },
                    label = { Text("맥 주소") },
                    singleLine = true,
                    enabled = !model.connecting,
                    modifier = Modifier.fillMaxWidth(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    trailingIcon = { TextButton(onClick = { model.loadHost() }) { Text("불러오기") } },
                )
                OutlinedTextField(
                    value = model.username,
                    onValueChange = { model.username = it },
                    label = { Text("맥 사용자 이름") },
                    singleLine = true,
                    enabled = !model.connecting,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = model.password,
                    onValueChange = { model.password = it },
                    label = { Text("맥 암호") },
                    singleLine = true,
                    enabled = !model.connecting,
                    visualTransformation = PasswordVisualTransformation(),
                    modifier = Modifier.fillMaxWidth(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                )
                Text("VNC 암호로 접속하려면 사용자 이름을 비워 주세요.", fontSize = 18.sp)
                Button(
                    onClick = { if (model.connecting) model.disconnect() else model.connect() },
                    modifier = Modifier.heightIn(min = 56.dp),
                ) {
                    Text(if (model.connecting) "취소" else "연결", fontSize = 20.sp)
                }
            }
        }
        if (model.message.isNotEmpty() && !model.settings)
            Text(
                model.message,
                modifier = Modifier.padding(12.dp),
                fontSize = 18.sp,
                color = MaterialTheme.colorScheme.error,
            )
    }
    if (model.settings) {
        LaunchedEffect(Unit) {
            surface?.showKeyboard(false)
            surface?.clearFocus()
            keyboard = false
        }
        var code by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { model.closeSettings() },
            title = { Text(if (model.pairing) "맥 연결 코드" else "해상도", fontSize = 24.sp) },
            text = {
                Column(
                    Modifier.heightIn(max = 450.dp).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    if (model.pairing) {
                        Text("맥의 Specula Display에 표시된 연결 코드를 입력하세요.", fontSize = 18.sp)
                        OutlinedTextField(
                            value = code,
                            onValueChange = { code = it.filter(Char::isDigit).take(6) },
                            label = { Text("연결 코드") },
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                            singleLine = true,
                        )
                    } else {
                        model.snapshot?.let { snap ->
                            Text("현재 ${snap.current.title}", fontSize = 18.sp)
                            snap.modes.forEach { mode ->
                                TextButton(
                                    onClick = { model.change(mode.id) },
                                    enabled = !model.busy,
                                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                                ) {
                                    Text(mode.title, fontSize = 20.sp)
                                }
                            }
                        }
                        TextButton(
                            onClick = {
                                model.display {
                                    it.restore()
                                    model.snapshot = it.modes()
                                }
                            },
                            enabled = !model.busy,
                        ) {
                            Text("원래 해상도 복원", fontSize = 18.sp)
                        }
                    }
                    if (model.busy) CircularProgressIndicator()
                    if (model.message.isNotEmpty())
                        Text(
                            model.message,
                            fontSize = 18.sp,
                            color = MaterialTheme.colorScheme.error,
                        )
                }
            },
            confirmButton = {
                if (model.pairing)
                    TextButton(
                        onClick = { model.pair(code) },
                        enabled = code.length == 6 && !model.busy,
                    ) {
                        Text("연결", fontSize = 20.sp)
                    }
            },
            dismissButton = {
                TextButton(onClick = { model.closeSettings() }) { Text("닫기", fontSize = 20.sp) }
            },
        )
    }
}

/** Bitmap reads stay in AndroidView's update scope, never in the controls' composition. */
@Composable
private fun RemoteScreen(model: SessionModel, onSurface: (RemoteSurface) -> Unit) {
    AndroidView(
        factory = { context ->
            RemoteSurface(context).also {
                onSurface(it)
                it.onRemoteTouch = model.commandTab::release
                it.pointer = model::pointer
                it.key = model::key
                it.text = model::text
                it.post {
                    it.requestFocus()
                    it.showKeyboard(false)
                }
            }
        },
        update = { it.frame = model.bitmap },
        modifier = Modifier.fillMaxSize(),
    )
}

/** An in-window menu keeps physical key dispatch on the Activity/RemoteSurface path. */
@Composable
private fun SessionControls(
    model: SessionModel,
    onKeyboard: () -> Unit,
    hideKeyboard: () -> Unit,
) {
    // This state belongs to the connected overlay, independent of framebuffer updates.
    var expanded by remember { mutableStateOf(false) }
    Box(Modifier.fillMaxSize()) {
        FilledTonalButton(
            onClick = { expanded = true }, // Opening the menu must keep Command held.
            modifier = Modifier.align(Alignment.TopEnd).padding(8.dp).size(56.dp),
            contentPadding = PaddingValues(0.dp),
        ) {
            Text("⋯", fontSize = 32.sp, modifier = Modifier.semantics {
                // Give TalkBack a useful name for the glyph.
                contentDescription = "세션 메뉴"
            })
        }
        if (model.commandTab.held) {
            Column(
                Modifier.align(Alignment.TopStart).padding(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FilledTonalButton(
                    onClick = { model.commandTab.tap() },
                    modifier = Modifier.widthIn(min = 56.dp).heightIn(min = 56.dp)
                        .semantics { selected = true },
                ) { Text("Tab", fontSize = 20.sp) }
                FilledTonalButton(
                    onClick = { model.commandTab.release() },
                    modifier = Modifier.widthIn(min = 56.dp).heightIn(min = 56.dp),
                ) { Text("⌘ 해제", fontSize = 20.sp) }
            }
        }
        if (expanded) {
            BackHandler { expanded = false }
            // A sibling above AndroidView consumes the entire outside gesture, including
            // its up event after dismissal. No remote click or Command release leaks through.
            Box(
                Modifier.fillMaxSize().clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClickLabel = "메뉴 닫기",
                    onClick = { expanded = false },
                ),
            )
            Surface(
                modifier = Modifier.align(Alignment.TopEnd).padding(
                    top = 72.dp, start = 8.dp, end = 8.dp, bottom = 8.dp,
                ).width(260.dp).semantics { paneTitle = "세션 메뉴" },
                shape = MaterialTheme.shapes.medium,
                tonalElevation = 6.dp,
                shadowElevation = 6.dp,
            ) {
                Column(Modifier.verticalScroll(rememberScrollState()).padding(vertical = 8.dp)) {
                    @Composable
                    fun Item(
                        title: String,
                        enabled: Boolean = true,
                        appSwitcher: Boolean = false,
                        action: () -> Unit,
                    ) {
                        DropdownMenuItem(
                            text = { Text(title, fontSize = 20.sp) },
                            enabled = enabled,
                            modifier = Modifier.heightIn(min = 56.dp),
                            onClick = {
                                expanded = false
                                if (!appSwitcher) model.commandTab.release()
                                action()
                            },
                        )
                    }
                    Item("키보드") { onKeyboard() }
                    Item("⌃Space 입력기") { model.inputSource() }
                    Item("⌘Tab", appSwitcher = true) { model.commandTab.tap() }
                    Item("해상도", enabled = !model.busy) {
                        hideKeyboard()
                        model.modes()
                    }
                    Item(if (model.portrait) "가로" else "세로", enabled = !model.busy) {
                        hideKeyboard()
                        model.rotate()
                    }
                    Item("연결 끊기") {
                        hideKeyboard()
                        model.disconnect()
                    }
                }
            }
        }
    }
}

package com.ias.specula

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.*
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.viewmodel.compose.viewModel

class MainActivity: ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState); enableEdgeToEdge()
        setContent { MaterialTheme { Surface(Modifier.fillMaxSize()) { Specula() } } }
    }
}
@Composable private fun Specula(model: SessionModel = viewModel()) {
    var surface by remember { mutableStateOf<RemoteSurface?>(null) }
    var keyboard by remember { mutableStateOf(false) }
    BackHandler(model.connected || model.connecting) { if(keyboard) { keyboard=false; surface?.showKeyboard(false) } else model.disconnect() }
    Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding()) {
        if(model.connected) {
            AndroidView(factory={ context -> RemoteSurface(context).also { surface=it; it.pointer=model::pointer; it.key=model::key; it.text=model::text } },
                update={ it.frame=model.bitmap },modifier=Modifier.weight(1f).fillMaxWidth())
            // Always one row; horizontal scroll preserves large labels on narrow screens or large font scales.
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal=4.dp),horizontalArrangement=Arrangement.spacedBy(4.dp)) {
                @Composable fun Control(title: String,enabled: Boolean=true,action: ()->Unit) {
                    TextButton(onClick=action,enabled=enabled,modifier=Modifier.heightIn(min=56.dp).widthIn(min=48.dp),contentPadding=PaddingValues(8.dp)) { Text(title,fontSize=18.sp,maxLines=1,softWrap=false) }
                }
                Control("키보드") { keyboard=!keyboard; surface?.showKeyboard(keyboard) }
                Control("⌃Space 입력기") { model.inputSource() }
                Control("해상도",!model.busy) { surface?.showKeyboard(false); keyboard=false; model.modes() }
                Control("세로/가로",!model.busy) { surface?.showKeyboard(false); keyboard=false; model.rotate() }
            }
        } else {
            Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(24.dp),verticalArrangement=Arrangement.spacedBy(16.dp)) {
                Text("스페큘라",style=MaterialTheme.typography.headlineLarge)
                Text("맥 화면 공유",fontSize=22.sp)
                OutlinedTextField(value=model.host,onValueChange={ model.host=it },label={ Text("맥 주소") },singleLine=true,enabled=!model.connecting,modifier=Modifier.fillMaxWidth(),keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Uri),
                    trailingIcon={ TextButton(onClick={ model.loadHost() }) { Text("불러오기") } })
                OutlinedTextField(value=model.username,onValueChange={ model.username=it },label={ Text("맥 사용자 이름") },singleLine=true,enabled=!model.connecting,modifier=Modifier.fillMaxWidth())
                OutlinedTextField(value=model.password,onValueChange={ model.password=it },label={ Text("맥 암호") },singleLine=true,enabled=!model.connecting,visualTransformation=PasswordVisualTransformation(),modifier=Modifier.fillMaxWidth(),keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Password))
                Text("VNC 암호로 접속하려면 사용자 이름을 비워 주세요.",fontSize=18.sp)
                Button(onClick={ if(model.connecting) model.disconnect() else model.connect() },modifier=Modifier.heightIn(min=56.dp)) { Text(if(model.connecting) "취소" else "연결",fontSize=20.sp) }
            }
        }
        if(model.message.isNotEmpty() && !model.settings) Text(model.message,modifier=Modifier.padding(12.dp),fontSize=18.sp,color=MaterialTheme.colorScheme.error)
    }
    if(model.settings) {
        LaunchedEffect(Unit) { surface?.showKeyboard(false); surface?.clearFocus(); keyboard=false }
        var code by remember { mutableStateOf("") }
        AlertDialog(onDismissRequest={ model.settings=false },title={ Text(if(model.pairing) "맥 연결 코드" else "해상도",fontSize=24.sp) },text={
            Column(Modifier.heightIn(max=450.dp).verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                if(model.pairing) {
                    Text("맥의 Specula Display에 표시된 연결 코드를 입력하세요.",fontSize=18.sp)
                    OutlinedTextField(value=code,onValueChange={ code=it.filter(Char::isDigit).take(6) },label={ Text("연결 코드") },keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Number),singleLine=true)
                } else {
                    model.snapshot?.let { snap -> Text("현재 ${snap.current.title}",fontSize=18.sp); snap.modes.forEach { mode ->
                        TextButton(onClick={ model.change(mode.id) },enabled=!model.busy,modifier=Modifier.fillMaxWidth().heightIn(min=48.dp)) { Text(mode.title,fontSize=20.sp) }
                    } }
                    TextButton(onClick={ model.display { it.restore(); model.snapshot=it.modes() } },enabled=!model.busy) { Text("원래 해상도 복원",fontSize=18.sp) }
                }
                if(model.busy) CircularProgressIndicator()
                if(model.message.isNotEmpty()) Text(model.message,fontSize=18.sp,color=MaterialTheme.colorScheme.error)
            }
        },confirmButton={ if(model.pairing) TextButton(onClick={ model.pair(code) },enabled=code.length==6 && !model.busy) { Text("연결",fontSize=20.sp) } },dismissButton={ TextButton(onClick={ model.settings=false }) { Text("닫기",fontSize=20.sp) } })
    }
}

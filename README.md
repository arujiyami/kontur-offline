Контур — офлайн для .gguf, Windows 10

Свой instruct-файл .gguf положи в папку models.
llama-server.exe сюда не вложен: это бинарник на ~42 МБ, а заливка из чата пишет только текст.

Скачай официальный Windows CPU-сборок llama.cpp и распакуй его в папку llama,
чтобы рядом со Start.bat лежал llama/llama-server.exe:

https://github.com/ggml-org/llama.cpp/releases/download/b11223/llama-b11223-bin-win-cpu-x64.zip

Потом запусти Start.bat и выбери оболочку «Офлайн».

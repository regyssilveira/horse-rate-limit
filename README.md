# Horse Rate Limit

Middleware de controle de limite de requisições (*Rate Limiting*) para o framework **Horse**. 
Projetado para ser de alta performance, thread-safe e compatível tanto com Delphi quanto com Lazarus/Free Pascal (FPC).

## ⚙️ Instalação

A instalação é simples e feita usando o gerenciador de pacotes [`boss`](https://github.com/HashLoad/boss):

```sh
boss install github.com/regyssilveira/horse-rate-limit
```

---

## ⚡️ Início rápido

```delphi
uses
  Horse,
  Horse.RateLimit;

begin
  // Usa a configuração padrão: 60 requisições por minuto por IP do cliente
  THorse.Use(THorseRateLimit.New);

  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('pong');
    end);

  THorse.Listen(9000);
end.
```

---

## 🔧 Configuração avançada

Você pode configurar limites personalizados, tempo de janela, armazenamento externo e mensagens de erro através da estrutura fluente `THorseRateLimitConfig`:

```delphi
uses
  Horse,
  Horse.RateLimit;

begin
  THorse.Use(THorseRateLimit.New(
    THorseRateLimitConfig.Default
      .Limit(10)                       // Máximo de 10 requisições
      .WindowSeconds(10)               // Janela de 10 segundos
      .ErrorMessage('Muitas requisições. Tente novamente mais tarde.')
  ));

  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('pong');
    end);

  THorse.Listen(9000);
end.
```

### Cabeçalhos de Resposta (Headers)

Em cada resposta HTTP, o middleware adiciona automaticamente os cabeçalhos padrão do mercado:

- `X-RateLimit-Limit`: O limite total permitido (ex: `10`).
- `X-RateLimit-Remaining`: O número de requisições restantes dentro da janela atual.
- `X-RateLimit-Reset`: O timestamp no formato Unix indicando quando o limite será zerado.
- `Retry-After`: Adicionado somente ao retornar erro `429 Too Many Requests`, indicando em segundos o tempo restante que o cliente deve aguardar antes de tentar novamente.

---

## 🔑 Gerador de Chave Customizado

Por padrão, a identificação dos clientes é feita a partir do IP remoto (`RemoteAddr` com fallback para `X-Forwarded-For`). Você pode implementar identificações customizadas (por exemplo, baseando-se em cabeçalhos de Token de API ou JWT):

```delphi
THorse.Use(THorseRateLimit.New(
  THorseRateLimitConfig.Default
    .Limit(100)
    .WindowSeconds(60)
    .KeyGenerator(
      function(Req: THorseRequest): string
      begin
        // Se o cliente possuir um token customizado no header, usamos ele como chave
        Result := Req.Headers['X-API-Key'];
        if Result = '' then
          Result := Req.RawWebRequest.RemoteAddr; // Senão, cai no IP normal
      end)
));
```

---

## 💾 Abstração de Armazenamento (`IHorseRateLimitStorage`)

Para aplicações enterprise com múltiplos servidores balanceados (cluster), você pode implementar o armazenamento em uma base de dados compartilhada (como Redis), implementando a interface `IHorseRateLimitStorage`:

```delphi
type
  THorseRateLimitRedisStorage = class(TInterfacedObject, IHorseRateLimitStorage)
  public
    function Evaluate(const AKey: string; ALimit: Integer; AWindowSeconds: Integer): THorseRateLimitInfo;
  end;
```
 E então, registre-o na configuração:

```delphi
THorse.Use(THorseRateLimit.New(
  THorseRateLimitConfig.Default
    .Storage(THorseRateLimitRedisStorage.Create)
));
```

---

## 📄 Licença

Licenciado sob a licença [MIT](LICENSE).

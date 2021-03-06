defmodule OauthAzureActivedirectory.Client do
  alias OAuth2.Client
  alias OAuth2.Strategy.AuthCode

  def client do
  	configset = config()

  	OAuth2.Client.new([
      strategy: __MODULE__,
      client_id: configset[:client_id],
      client_secret: configset[:client_secret],
      redirect_uri: configset[:redirect_uri],
      authorize_url: "https://login.microsoftonline.com/#{configset[:tenant]}/oauth2/authorize",
      token_url: "https://login.microsoftonline.com/#{configset[:tenant]}/oauth2/token"
    ])
  end

  def authorize_url!(params \\ []) do
    oauth_session = SecureRandom.uuid
    
  	params = Map.update(params, :response_mode, "form_post", &(&1 * "form_post"))
    params = Map.update(params, :response_type, "code id_token", &(&1 * "code id_token"))
    params = Map.update(params, :nonce, oauth_session, &(&1 * oauth_session))
    Client.authorize_url!(client(), params)
  end

  def authorize_url(client, params) do
    AuthCode.authorize_url(client, params)
  end

  def process_callback!(%{params: %{"id_token" => id_token, "code" => code}}) do
    public_key = jwks_uri() |> get_discovery_keys |> get_public_key

    # verify with RSA SHA256 algorithm
    public = JsonWebToken.Algorithm.RsaUtil.public_key public_key

    opts = %{
      alg: "RS256",
      key: public
    }
    case JsonWebToken.verify(id_token, opts) do
      {:ok, claims} -> verify_token(code, claims)
      {:error} -> {:error, false}
    end
  end

  defp config do
    Application.get_env(:oauth_azure_activedirectory, OauthAzureActivedirectory.Client)
  end

  defp jwks_uri do
    body = http_request open_id_configuration()
    {status, list} = JSON.decode(body)
    if status == :ok, do: list["jwks_uri"], else: nil
  end

  defp http_request(url) do
    cacert =  :code.priv_dir(:oauth_azure_activedirectory) ++ '/BaltimoreCyberTrustRoot.crt.pem'
    :httpc.set_options(socket_opts: [verify: :verify_peer, cacertfile: cacert])
     
    case :httpc.request(:get, {to_charlist(url), []}, [], []) do
      {:ok, response} -> 
          {{_, 200, 'OK'}, _headers, body} = response
          body
      {:error} -> false
    end
  end
  
  defp get_discovery_keys(url)do
    list_body = http_request url
    {status, list} = JSON.decode list_body

    case status do
      :ok -> Enum.at(list["keys"], 0)["x5c"]
      :error -> nil
    end
  end

  defp get_public_key(cert) do
    certificate = "-----BEGIN CERTIFICATE-----\n#{cert}\n-----END CERTIFICATE-----\n"
    spki = certificate |> :public_key.pem_decode |> hd |> :public_key.pem_entry_decode |> elem(1) |> elem(7)
    :public_key.pem_entry_encode(:SubjectPublicKeyInfo, spki) |> List.wrap |> :public_key.pem_encode
  end

  defp open_id_configuration do
    "https://login.microsoftonline.com/common/.well-known/openid-configuration"
  end

  defp verify_token(code, claims) do
    # TODO had to remove uuid verification, needs a fix
    verify_chash(code, claims) |> verify_client
  end

  defp verify_chash(code, claims) do
    full_hash = :crypto.hash(:sha256, code)
    chash_length = (String.length(full_hash) / 2.0 - 1.0) |> round

    c_hash = String.slice(full_hash, 0..chash_length) |> Base.url_encode64(padding: false)
    if c_hash == claims[:c_hash], do: claims, else: false
  end

  defp verify_client(claims) do
    configset = config()
    if configset[:client_id] == claims[:aud], do: {:ok, claims}, else: {:error, false}
  end
end
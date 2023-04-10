-- Copyright 2023 Pangea Cyber Corporation
-- Author: Pangea Cyber Corporation


module Main exposing (main)

import Browser
import Browser.Dom as Dom
import Css exposing (..)
import Css.Global as Global
import Html.Styled as Html exposing (Html)
import Html.Styled.Attributes as Attrs exposing (css, href)
import Html.Styled.Events exposing (onInput, onSubmit)
import Http
import Json.Decode as JD
import Json.Encode as JE
import List.Extra as LE
import SyntaxHighlight as SH
import Task


main : Program () Model Msg
main =
    Browser.document
        { init = \_ -> init
        , view = view
        , update = update
        , subscriptions = \_ -> Sub.none
        }


chatContainerId : String
chatContainerId =
    "chat-container"


scrollToNewestChat : Cmd Msg
scrollToNewestChat =
    Dom.setViewportOf chatContainerId 0 100000000
        |> Task.attempt (always NoOp)


type Role
    = User
    | Assistant


roleToString : Role -> String
roleToString role =
    case role of
        User ->
            "user"

        Assistant ->
            "assistant"


roleDecoder : JD.Decoder Role
roleDecoder =
    JD.string
        |> JD.andThen
            (\s ->
                case s of
                    "user" ->
                        JD.succeed User

                    "assistant" ->
                        JD.succeed Assistant

                    _ ->
                        JD.fail (s ++ " is not a valid Role")
            )


type alias ChatMessage =
    { role : Role
    , content : String
    }


encodeChatMessage : ChatMessage -> JE.Value
encodeChatMessage { role, content } =
    JE.object
        [ ( "role", JE.string (roleToString role) )
        , ( "content", JE.string content )
        ]


chatMessageDecoder : JD.Decoder ChatMessage
chatMessageDecoder =
    JD.map2 ChatMessage
        (JD.field "role" roleDecoder)
        (JD.field "content" JD.string)


type alias ServerResponse =
    { previous : List ( ChatMessage, String )
    , chatGPTMessage : ChatMessage
    , chatGPTRedacted : String
    , userRedacted : String
    , rawRedactUserText : String
    , rawRedactGptText : String
    }


previousDecoder : List JD.Value -> JD.Decoder ( ChatMessage, String )
previousDecoder values =
    case values of
        rawMessage :: rawRedaction :: _ ->
            Result.map2 (\a b -> JD.succeed <| Tuple.pair a b)
                (JD.decodeValue chatMessageDecoder rawMessage)
                (JD.decodeValue JD.string rawRedaction)
                |> Result.withDefault (JD.fail "Invalid values for previous message member")

        _ ->
            JD.fail "Invalid values for previous message member"


encodePrevious : List ( ChatMessage, String ) -> JE.Value
encodePrevious =
    JE.list
        (\( message, redaction ) ->
            JE.list identity [ encodeChatMessage message, JE.string redaction ]
        )


serverResponseDecoder : JD.Decoder ServerResponse
serverResponseDecoder =
    JD.map6 ServerResponse
        (JD.field "previous" (JD.list (JD.list JD.value |> JD.andThen previousDecoder)))
        (JD.field "chat_gpt_message" chatMessageDecoder)
        (JD.field "chat_gpt_redacted" JD.string)
        (JD.field "user_redacted" JD.string)
        (JD.field "raw_redact_user_text" JD.string)
        (JD.field "raw_redact_gpt_text" JD.string)


serverRequest : List ( ChatMessage, String ) -> String -> JE.Value
serverRequest previous message =
    JE.object
        [ ( "previous", encodePrevious previous )
        , ( "message", JE.string message )
        ]


chatCall : List ( ChatMessage, String ) -> String -> Cmd Msg
chatCall previous message =
    Http.post
        { url = "/chat"
        , body = Http.jsonBody (serverRequest previous message)
        , expect = Http.expectJson MessageReceived serverResponseDecoder
        }


type alias Model =
    { previousMessages : List ( ChatMessage, String )
    , currentText : String
    , chatMessages : List ( ChatMessage, Maybe String )
    , errors : List String
    , isLoading : Bool
    , rawUserRedactText : String
    , rawGptRedactText : String
    }


init : ( Model, Cmd Msg )
init =
    ( { previousMessages = []
      , currentText = ""
      , chatMessages = []
      , errors = []
      , isLoading = False
      , rawUserRedactText = ""
      , rawGptRedactText = ""
      }
    , Cmd.none
    )


type Msg
    = NoOp
    | TextInput String
    | TextSubmitted
    | MessageReceived (Result Http.Error ServerResponse)


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        NoOp ->
            ( model, Cmd.none )

        TextInput txt ->
            ( { model | currentText = txt }, Cmd.none )

        MessageReceived result ->
            case result of
                Ok response ->
                    ( { model
                        | chatMessages =
                            addRedacted response.userRedacted model.chatMessages
                                ++ [ ( response.chatGPTMessage, Just response.chatGPTRedacted ) ]
                        , isLoading = False
                        , previousMessages = response.previous
                        , rawUserRedactText = response.rawRedactUserText
                        , rawGptRedactText = response.rawRedactGptText
                      }
                    , scrollToNewestChat
                    )

                Err err ->
                    let
                        errorMessage =
                            case err of
                                Http.Timeout ->
                                    "Request timed out, check the server"

                                Http.NetworkError ->
                                    "Network Error"

                                Http.BadStatus code ->
                                    "Received a bad status of: " ++ String.fromInt code

                                Http.BadBody e ->
                                    "Received a bad body: " ++ e

                                _ ->
                                    "Internal Error"
                    in
                    ( { model | errors = errorMessage :: model.errors }, Cmd.none )

        TextSubmitted ->
            ( { model
                | currentText = ""
                , isLoading = True
                , chatMessages =
                    model.chatMessages
                        ++ [ ( { role = User, content = model.currentText }, Nothing ) ]
                , rawUserRedactText = ""
                , rawGptRedactText = ""
              }
            , Cmd.batch [ scrollToNewestChat, chatCall model.previousMessages model.currentText ]
            )


view : Model -> Browser.Document Msg
view model =
    { title = "Pangea GPT"
    , body =
        List.map
            Html.toUnstyled
            [ Html.node "link"
                [ Attrs.rel "stylesheet"
                , href "https://unpkg.com/@picocss/pico@1.*/css/pico.min.css"
                ]
                []
            , Global.global
                [ Global.selector "body"
                    [ overflow hidden ]
                ]
            , chatPage model
            ]
    }


chatPage : Model -> Html Msg
chatPage model =
    Html.node "main"
        [ css
            [ minHeight (vh 100)
            , displayFlex
            , paddingLeft (rem 5)
            , paddingRight (rem 5)
            , paddingTop (rem 2)
            , paddingBottom (rem 2)
            , overflow hidden
            ]
        ]
        [ Html.div
            [ css
                [ width (pct 50)
                , position relative
                ]
            ]
          <|
            List.map errorView model.errors
                ++ [ chatMessages model.chatMessages
                   , messageBox model.isLoading model.currentText
                   ]
        , Html.div
            [ css
                [ width (pct 50)
                , position relative
                , padding (rem 2)
                , overflowY auto
                , maxHeight (vh 100)
                ]
            ]
            [ jsonView "User Redaction Payload" model.rawUserRedactText
            , jsonView "GPT Redaction Payload" model.rawGptRedactText
            ]
        ]


chatMessages : List ( ChatMessage, Maybe String ) -> Html Msg
chatMessages messages =
    List.map chatMessage messages
        |> Html.div
            [ css
                [ marginBottom (rem 5)
                , maxHeight (vh 80)
                , overflowY auto
                ]
            , Attrs.id chatContainerId
            ]


chatMessage : ( ChatMessage, Maybe String ) -> Html Msg
chatMessage ( message, redaction ) =
    let
        sender =
            case message.role of
                User ->
                    "User"

                Assistant ->
                    "Chat GPT"

        busy =
            case redaction of
                Nothing ->
                    "true"

                Just _ ->
                    "false"
    in
    Html.p
        []
        [ Html.h5
            [ css
                [ marginBottom (px 1)
                ]
            ]
            [ Html.text <| sender ++ ":" ]
        , Html.text message.content
        , Html.br [] []
        , Html.span
            [ css [ marginBottom (px 1), fontWeight bold ]
            ]
            [ Html.text "Redacted Text" ]
        , Html.br [] []
        , Html.span
            [ Attrs.attribute "aria-busy" busy ]
            [ Html.text (Maybe.withDefault "" redaction) ]
        ]


messageBox : Bool -> String -> Html Msg
messageBox loading text =
    Html.div
        [ css
            [ position fixed
            , bottom (px 1)
            , width inherit
            , paddingRight (pct 5)
            ]
        ]
        [ Html.form
            [ onSubmit TextSubmitted
            ]
            [ Html.input
                [ Attrs.placeholder "Send a message"
                , Attrs.value text
                , onInput TextInput
                , Attrs.disabled loading
                ]
                []
            , Html.input
                [ Attrs.type_ "submit"
                , css [ display none ]
                ]
                []
            ]
        ]


addRedacted : String -> List ( ChatMessage, Maybe String ) -> List ( ChatMessage, Maybe String )
addRedacted redaction messages =
    LE.updateAt (List.length messages - 1) (Tuple.mapSecond (always <| Just redaction)) messages


errorView : String -> Html Msg
errorView error =
    Html.div
        [ Attrs.attribute "role" "alert"
        , css
            [ backgroundColor (hex "ffebee")
            , backgroundSize (px 30)
            , color (hex "b71c1c")
            , padding (px 10)
            , marginBottom (px 5)
            ]
        ]
        [ Html.text error ]


jsonView : String -> String -> Html Msg
jsonView title rawJSON =
    if String.isEmpty rawJSON then
        Html.text ""

    else
        Html.div
            []
            [ Html.h5 [] [ Html.text title ]
            , SH.useTheme SH.monokai |> Html.fromUnstyled
            , SH.json rawJSON
                |> Result.map (SH.toBlockHtml (Just 1) >> Html.fromUnstyled)
                |> Result.withDefault (Html.pre [] [ Html.text rawJSON ])
            ]

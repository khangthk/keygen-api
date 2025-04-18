# frozen_string_literal: true

require_relative "./logger"

module Keygen
  module Middleware
    # FIXME(ezekg) Rails emits a lot of errors that can't be rescued within
    #              our ApplicationController. So here we are.
    #
    class RequestErrorWrapper
      def initialize(app)
        @app = app
      end

      def call(env)
        @app.call env
      rescue ActionDispatch::Http::Parameters::ParseError,
             Rack::QueryParser::InvalidParameterError,
             Rack::QueryParser::ParameterTypeError,
             ActionController::BadRequest,
             Encoding::CompatibilityError,
             JSON::ParserError,
             ArgumentError => e
        message = e.message.scrub

        case message
        when /incomplete multibyte character/,
             /invalid escaped character/,
             /invalid byte sequence/
          [
            400,
            {
              "Content-Type" => "application/vnd.api+json; charset=utf-8",
            },
            [{
              errors: [{
                title: "Bad request",
                detail: "The request could not be completed because it contains an invalid byte sequence (check encoding)",
                code: "ENCODING_INVALID"
              }]
            }.to_json]
          ]
        when /string contains null byte/
          [
            400,
            {
              "Content-Type" => "application/vnd.api+json; charset=utf-8",
            },
            [{
              errors: [{
                title: "Bad request",
                detail: "The request could not be completed because it contains an unexpected null byte (check encoding)",
                code: "ENCODING_INVALID"
              }]
            }.to_json]
          ]
        when /query parameters/
          [
            400,
            {
              "Content-Type" => "application/vnd.api+json; charset=utf-8",
            },
            [{
              errors: [{
                title: "Bad request",
                detail: "The request could not be completed because it contains invalid query parameters (check encoding)",
                code: "PARAMETERS_INVALID"
              }]
            }.to_json]
          ]
        else
          if e.is_a?(ArgumentError)
            # Special case (report error and consider this a bug)
            Keygen.logger.exception(e)

            [
              500,
              {
                "Content-Type" => "application/vnd.api+json; charset=utf-8",
              },
              [{
                errors: [{
                  title: "Internal server error",
                  detail: "Looks like something went wrong! Our engineers have been notified. If you continue to have problems, please contact support@keygen.sh.",
                }]
              }.to_json]
            ]
          else
            [
              400,
              {
                "Content-Type" => "application/vnd.api+json; charset=utf-8",
              },
              [{
                errors: [{
                  title: "Bad request",
                  detail: "The request could not be completed because it contains invalid JSON (check formatting/encoding)",
                  code: "JSON_INVALID"
                }]
              }.to_json]
            ]
          end
        end
      rescue ActionController::RoutingError => e
        message = e.message.scrub

        case message
        when /bad URI\(is not URI\?\)/
          [
            400,
            {
              "Content-Type" => "application/vnd.api+json; charset=utf-8",
            },
            [{
              errors: [{
                title: "Bad request",
                detail: "The request could not be completed because the URI was invalid (please ensure non-URL safe chars are properly encoded)",
                code: "URI_INVALID"
              }]
            }.to_json]
          ]
        else
          [
            404,
            {
              "Content-Type" => "application/vnd.api+json; charset=utf-8",
            },
            [{
              errors: [{
                title: "Not found",
                detail: "The requested endpoint was not found (check your HTTP method, Accept header, and URL path)",
                code: "NOT_FOUND",
              }]
            }.to_json]
          ]
        end
      rescue Rack::Timeout::RequestTimeoutException,
             Rack::Timeout::Error,
             Timeout::Error => e
        Keygen.logger.exception(e)

        [
          503,
          {
            "Content-Type" => "application/vnd.api+json; charset=utf-8",
          },
          [{
            errors: [{
              title: "Request timeout",
              detail: "The request timed out because the server took too long to respond"
            }]
          }.to_json]
        ]
      rescue ActionController::UnknownHttpMethod => e
        [
          400,
          {
            "Content-Type" => "application/vnd.api+json; charset=utf-8",
          },
          [{
            errors: [{
              title: "Bad request",
              detail: "The HTTP method for the request is not valid",
              code: "HTTP_METHOD_INVALID"
            }]
          }.to_json]
        ]
      rescue Mime::Type::InvalidMimeType
        [
          400,
          {
            "Content-Type" => "application/vnd.api+json; charset=utf-8",
          },
          [{
            errors: [{
              title: "Bad request",
              detail: "The mime type of the request is not acceptable (check content-type and accept headers)",
              code: "MIME_TYPE_INVALID"
            }]
          }.to_json]
        ]
      end
    end

    class DefaultContentType
      def initialize(app)
        @app = app
      end

      def call(env)
        begin
          request      = ActionDispatch::Request.new(env)
          content_type = request.content_type
          user_agent   = request.user_agent
          method       = request.method
          path         = request.path

          # special snowflake cases
          case { method:, path: }
          in method: 'PUT', path: %r(/artifact$) if user_agent.present?
            # electron-builder < v24.6.3 sets a JSON content-type, but it actually sends
            # binary data. This ends up exploding on our end because Rails attempts to
            # parse the request as JSON, and rightfully so, but it's actually an app
            # binary. Rather than wait on a patch and backport for electron-builder,
            # and for everybody to upgrade, we'll assume binary.
            #
            # FIXME(ezekg) Only applies to the legacy v1.0 endpoint. Let's eventually
            #              deprecate this as integrations upgrade electron-builder.
            if user_agent.starts_with?('electron-builder')
              env['CONTENT_TYPE'] = 'application/octet-stream'
            end
          in method: 'POST' | 'PUT' | 'PATCH' | 'DELETE' if content_type.to_s =~ /^([^,;]*)/
            mime_type, * = Mime::Type.parse($1.strip.downcase)

            # Whenever an API request is sent without a content-type header, some clients,
            # such as `fetch()` or curl, use these headers by default. We're going to try
            # to parse the request as JSON and error later, instead of rejecting the request
            # off the bat. In theory, this would slightly improve onboarding DX.
            #
            # FIXME(ezekg) This was a terrible idea and I'd like to deprecate it.
            if content_type.blank? || (mime_type in Mime::Type[:url_encoded_form | :multipart_form | :text])
              env['CONTENT_TYPE'] = 'application/json'
            end
          else
            # leave as-is
          end
        rescue Mime::Type::InvalidMimeType
          # will be handled later
        rescue => e
          Keygen.logger.exception(e)
        end

        @app.call(env)
      end
    end

    class IgnoreForwardedHost
      def initialize(app)
        @app = app
      end

      def call(env)
        # Whenever an API request is received that originated via a proxy, such as
        # from Vercel/Next.js, this header may be set and it may be a different
        # value than our allowed hosts. Unfortunately, Rails uses this header
        # along with Host to authorize against our allowed hosts, so this
        # raises a 403 error for the bad host header.
        #
        # Since we don't use this header, and its only purpose is for telling
        # us the host used in the original request, before being proxied to
        # us, we can strip it out without consequence.
        #
        # See: https://github.com/rails/rails/issues/29893
        env.delete('HTTP_X_FORWARDED_HOST')

        @app.call(env)
      end
    end

    class RewriteAcceptAll
      def initialize(app) = @app = app
      def call(env)
        # please lord give me strength (some real clients send * even though it's invalid)
        env['HTTP_ACCEPT'] = '*/*' if env['HTTP_ACCEPT'] == '*'

        @app.call(env)
      end
    end

    # NOTE(ezekg) see: https://github.com/rack/rack/issues/2130
    class PartitionedCookies
      def initialize(app) = @app = app
      def call(env)
        status, headers, body = @app.call(env)

        # add support for partitioned cookies
        cookie = headers['Set-Cookie']
        if cookie in /samesite=None/i
          cookie.gsub!(/samesite=None/i, 'samesite=None; partitioned')
        end

        [status, headers, body]
      end
    end
  end
end

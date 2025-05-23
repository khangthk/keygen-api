# frozen_string_literal: true

require 'minitar'

require Rails.root / 'lib/oci_image_layout'

class ProcessOciImageWorker < BaseWorker
  MIN_TARBALL_SIZE  = 512.bytes     # to avoid processing empty or invalid tarballs
  MAX_TARBALL_SIZE  = 1.gigabyte    # to avoid downloading excessive tarballs
  MAX_MANIFEST_SIZE = 1.megabyte    # to avoid storing large manifests
  MAX_BLOB_SIZE     = 512.megabytes # to avoid storing large layers

  sidekiq_options queue: :critical,
                  retry: false

  def perform(artifact_id)
    artifact = ReleaseArtifact.find(artifact_id)
    return unless
      artifact.processing?

    # sanity check the image tarball
    min_filesize, max_filesize = MIN_TARBALL_SIZE, artifact.account.max_upload.presence || MAX_TARBALL_SIZE

    unless artifact.content_length.in?(min_filesize..max_filesize)
      raise ImageNotAcceptableError, 'unacceptable filesize'
    end

    # download the image tarball in chunks to reduce memory footprint
    client = artifact.client
    enum   = Enumerator.new do |yielder|
      client.get_object(bucket: artifact.bucket, key: artifact.key) do |chunk|
        yielder << chunk
      end
    end

    # wrap the enumerator to provide an IO-like interface
    tar = EnumeratorIO.new(enum)

    # unpack the image tarball
    unpack tar do |archive|
      layout = OciImageLayout.parse(archive)

      layout.each do |item|
        next unless
          item.exists?

        # store indexes and manifests as a manifest for reference without hitting storage provider
        if item in OciImageLayout::Index | OciImageLayout::Manifest => descriptor
          raise ImageNotAcceptableError, 'manifest is too big' if
            descriptor.size > MAX_MANIFEST_SIZE

          ReleaseManifest.create!(
            account_id: artifact.account_id,
            environment_id: artifact.environment_id,
            release_id: artifact.release_id,
            release_artifact_id: artifact.id,
            content_type: descriptor.media_type,
            content_digest: descriptor.digest,
            content_length: descriptor.size,
            content_path: descriptor.path,
            content: descriptor.read,
          )

          # still need to read/store it as a blob
          descriptor.rewind
        end

        # store blobs as a descriptor pointing to the storage provider
        if item in OciImageLayout::Blob => blob
          raise ImageNotAcceptableError, 'blob is too big' if
            blob.size > MAX_BLOB_SIZE

          descriptor = ReleaseDescriptor.create!(
            account_id: artifact.account_id,
            environment_id: artifact.environment_id,
            release_id: artifact.release_id,
            release_artifact_id: artifact.id,
            content_type: blob.media_type,
            content_digest: blob.digest,
            content_length: blob.size,
            content_path: blob.path,
          )

          # don't reupload if blob already exists
          next if
            client.head_object(bucket: descriptor.bucket, key: descriptor.key).successful? rescue false

          # TODO(ezekg) this should accept a block like get_object to support chunked writes
          #             see: https://github.com/aws/aws-sdk-ruby/issues/3142
          client.put_object(
            bucket: descriptor.bucket,
            key: descriptor.key,
            content_length: descriptor.content_length,
            content_type: descriptor.content_type,
            body: blob.to_io,
          )
        end
      rescue ActiveRecord::RecordNotUnique => e
        # FIXME(ezekg) sometimes we get the same item more than once when
        #              live-streaming an in-progress upload
        Keygen.logger.warn { "[workers.process-oci-image-worker] Error: #{e.class.name} - #{e.message}" }
      end
    end

    artifact.update!(status: 'UPLOADED')

    BroadcastEventService.call(
      event: 'artifact.upload.succeeded',
      account: artifact.account,
      resource: artifact,
    )
  rescue ImageNotAcceptableError,
         OciImageLayout::Error,
         ActiveRecord::RecordInvalid,
         JSON::ParserError,
         Minitar::UnexpectedEOF,
         Minitar::Error,
         IOError => e
    Keygen.logger.warn { "[workers.process-oci-image-worker] Error: #{e.class.name} - #{e.message}" }

    artifact.update!(status: 'FAILED')

    BroadcastEventService.call(
      event: 'artifact.upload.failed',
      account: artifact.account,
      resource: artifact,
    )
  end

  private

  def unpack(io, &)
    Minitar::Reader.open(io, &)
  rescue ArgumentError => e
    case e.message
    when /is not a valid octal string/ # octal encoding error
      raise ImageNotAcceptableError, e.message
    else
      raise e
    end
  end

  class ImageNotAcceptableError < StandardError
    def backtrace = nil # silence backtrace
  end
end
